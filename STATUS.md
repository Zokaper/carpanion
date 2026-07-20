# Status log

Recent/active work, newest entry on top. One entry per chunk of work — what changed, why,
and what's left/next if anything. Standing project info (architecture, how things work)
belongs in `AGENTS.md`, not here. When this file gets long, move older entries into
`STATUS_ARCHIVE.md` (keep the newest ~10-15 entries here).

---

## 2026-07-20 — Claude — V4.5: move single-song favorites and artist-only mode onto native too

Per user: collab is now understood as its own separate feature (only turned on when passengers
are in the car, building their own playlist from scratch, unrelated to favorites) — so single-song
favorites no longer need the app-owned collab queue; that was only there so a passenger could
queue-add after it. Also asked whether "Play Artist → artist only" (not radio) could go native.

**Native single-song playback** — `MainActivity.kt`'s `"playNativeMix"` handler required `listId`;
relaxed it to accept `videoId` alone (builds a bare `watch?v=<videoId>`, no `list=`, so YT Music
builds its own autoplay radio around it — same passive-mirror idea as everything else native).
`CollabService.playNativeMix` signature changed from `{required String listId}` to
`{String? listId, String? videoId}` (asserts at least one). `main.dart`'s song-favorite branch now
calls `collab.playNativeMix(videoId: vid)` instead of the old `collab.playFavoriteSong(...)`
(removed — collab_service.dart's `playFavoriteSong`, now unused, deleted).

**Artist-only mode → native** — added `YouTubeService.getArtistSongsPlaylistId(artist)` (resolves
the artist's own "Songs" shelf playlist id, reusing `_findSongsPlaylistId` — the same lookup
`getArtistTracks` already did internally). `main.dart`'s artist non-radio branch now tries this
first via `playNativeMix(listId: ...)`, falling back to the old `getArtistTracks`/`loadQueueAndPlay`
path if no id is found. **Trade-off surfaced to and accepted by the user**: this loses the app's
own weighted-random shuffle (`getArtistTracks`'s `_weightedShuffle` — a different order each tap,
weighted toward popular songs) in favor of YT Music's fixed playlist order.

**Bug caught + fixed during on-device testing**: `_findSongsPlaylistId` returns a browse id
("VLOLAK5uy…", for paging through the shelf), not a watch-playlist id — passing it straight to
`playNativeMix` made `playFromUri` report `success: true` but YT Music silently failed to load it
and kept playing whatever was already on. Same normalization the home-tile mix path already
applies (`main.dart`'s `pid.startsWith('VL') ? pid.substring(2) : pid`) was missing here;
`getArtistSongsPlaylistId` now strips a leading "VL" itself before returning.

Verified on-device: a song favorite now shows NATIVE and lets YT Music's own autoplay take over
after it (confirmed with "the cure" → Lana Del Rey "Radio" autoplay); "Play Artist" (artist-only)
on Nessa Barrett now plays her own Songs playlist natively (P*RNSTAR → Love Looks Pretty On You →
…), confirmed only after finding/fixing the VL-prefix bug above — first attempt silently kept
playing the previous track. `flutter analyze` clean; Kotlin change compiles (verified via
`flutter build apk --debug`).

---

## 2026-07-20 — Claude — V4.5 polish follow-up 2: fix wrong track archived into a new mix's history

User report: selecting Supermix while "Nothing's New" was playing (from an unrelated album)
started Supermix correctly, but "Nothing's New" got shown as if it were part of Supermix's
history — and tapping it to go back didn't work, since it was never actually in that queue.

Root cause (`main.dart`): `CollabService.playNativeMix` calls `DashboardProvider.
clearNativeQueueHistory()` to reset history for the new mix, but that only cleared the history
list — it left `_nativeActiveQueueItemId` pointing at whatever was active before. When the
real queue-transition event arrived a moment later, `_startMediaEventListener`'s archiving
logic saw "the active item changed" and, having no way to know this was a session boundary
(new mix) rather than an organic same-mix advance, archived the old item into the (freshly
cleared) history as if it belonged to the new mix.

Fix: `clearNativeQueueHistory()` now also resets `_nativeActiveQueueItemId = -1`, which makes
the archiving logic's existing `_nativeActiveQueueItemId != -1` guard skip that first archive
after a fresh mix trigger — no new flag needed, reused the existing safety check. Verified
on-device: played a Lana Del Rey album track ("Norman fucking Rockwell"), switched to Supermix,
confirmed the album track does not appear anywhere in Supermix's queue/history and Supermix's
own first track ("Born To Die") sits at the top with nothing above it.

---

## 2026-07-20 — Claude — V4.5 polish follow-up: fix breakage from switching between dynamic queues

User report: "when you press a dynamic queue then you press on another one" — Play Artist/Album,
next/previous, and a pixel overflow all broke. Reproduced on-device (real S25+) and found two
distinct, pre-existing bugs (not introduced by the picker feature itself, but the picker made
one of them visible/consequential):

1. **Header pixel overflow** (`queue_tab.dart` `_buildHeader`): the icon row is 4 fixed-48px
   icons in native mode but 5 in collab mode (an extra "Clear Queue" icon appears when
   `!isNative && ytService.currentQueue.isNotEmpty`) — 5×48=240px doesn't fit the panel width
   (~237.6px), a pre-existing latent bug that simply hadn't been triggered in prior testing
   sessions. Confirmed trigger: tapping "Quick Picks" (which — per existing, intentional
   architecture — goes through the old collab-queue path, not `playNativeMix`, since it's a
   curated song shelf with no playlist id) switches to collab mode with a non-empty queue.
   Fixed by wrapping the header `Row` in `FittedBox(fit: BoxFit.scaleDown)` so it scales down
   instead of overflowing whenever the 5th icon appears.
2. **Stale album metadata** (`main.dart` `_startMediaEventListener`): confirmed on-device that
   after a fast track transition (Next button, or any native skip), "Play Album" could offer
   the *previous* track's album. Root cause: the fast media_events push only updates
   `_currentAlbum` when its own payload happens to carry a non-empty `album` field (not always
   populated synchronously right after a skip); the slower polling loop that reliably re-fetches
   album via `getCurrentMediaMetadata` is gated on the same title/artist-changed check that the
   fast listener already satisfies first, so it never got a chance to correct it — `_currentAlbum`
   could stay wrong for the rest of that song. Fixed by having the event listener fall back to
   the same `getCurrentMediaMetadata` platform call when its own `album` field is empty.
   Confirmed fixed on-device: re-tapping immediately after a skip now shows the correct album.

Verified next/previous and the Play Album/Artist picker are unaffected by native→native mix
switches (tested Supermix → Replay Mix; both worked cleanly, no overflow). `flutter analyze`
clean on all three touched files.

---

## 2026-07-20 — Claude — V4.5 polish: native queue reflow, Supermix+QuickPicks, album/artist re-tap picker

Three requested polish items ahead of V5, all verified on-device (real S25+ over wireless adb):

1. **Native queue reflow jank** — `queue_tab.dart`'s `_buildNativeQueueList` had no per-row
   `key` and used plain `Container`/`Text`, so every `media_events` push (which wholesale-
   replaces `DashboardProvider._nativeQueue`) caused abrupt index-based content swaps instead
   of a cross-fade. Added `ValueKey(item['queueId'])` per row plus `AnimatedContainer`/
   `AnimatedDefaultTextStyle` (220ms) for the highlight/text-color transition.
2. **Supermix + Quick Picks not always in the mix grid** — `fetchHomeTiles()` now
   force-selects both by name before running the old `prefs` fallback loop, so a
   lower-priority tile can no longer bump a successfully-parsed Quick Picks out of the top 4.
   Also found (via on-device testing) that Quick Picks' shelf-detection itself is flaky —
   one fresh fetch returned 0 quick-picks candidates entirely (not a selection-logic issue,
   the shelf just didn't parse that time) — added a one-shot retry (`_quickPicksTile` on a
   fresh `FEmusic_home` browse) when the first pass comes up empty. Confirmed on-device this
   recovers a case that failed on the first attempt.
3. **New feature: re-tap the playing native-queue row → Play Album / Play Artist** — tapping
   the already-playing row now opens a bottom sheet instead of no-op'ing
   `nativeSkipToQueueItem`. Play Album resolves `getAlbumPlaylistId(currentAlbum,
   currentArtist)`, triggers it via `playNativeMix`, then waits (one-shot `DashboardProvider`
   listener, 5s timeout) for the same track title to reappear as the active queue item before
   calling `seekTo()` to resume near the original timestamp — confirmed on-device (resumed
   within ~1s of the captured position). Play Artist resolves `getArtistRadioPlaylistId`.
   Either option is disabled (not hidden-and-crashing) when `currentAlbum`/`currentArtist` is
   empty — confirmed on-device for a track with no album metadata yet.

**Bug found + fixed while testing #3**: `_pickAlbumId`/`_albumScore` (pre-existing, used by
both `getAlbumTracks` and `getAlbumPlaylistId`) scored candidates on album-title overlap only
and never looked at the artist — confirmed on-device it picked a completely unrelated artist's
album (Juice WRLD's "Death Race For Love (Bonus Track Version)" resolved to "$lux — Death
Race") because both titles partially substring-matched and tied on the length tiebreaker.
Added `_rendererSubtitle` (reads the "Album • Artist • Year" subtitle search rows carry) and
an artist-match term (±60) to `_albumScore`, now passed `artist` from both callers. Confirmed
fixed for the Juice WRLD case (now stays same-artist). **Not fully fixed**: a same-artist
case (Rio Romeo) still resolved a different album than intended ("Good Grief!" instead of the
currently-playing "Good God!") — likely the exact title with punctuation isn't surfacing in
the Innertube search results the way `_pickAlbumId` expects. This is the same "written without
live-response validation" risk AGENTS.md already flags for album/artist parsing; root-causing
it needs a live JSON dump (`debugDumpHome`-style), left as a follow-up, not chased further this
session since the artist-safety fix (never play a stranger's album) is the higher-value win and
is confirmed working.

`puro flutter analyze` clean on `queue_tab.dart`/`youtube_service.dart` (only pre-existing
`withOpacity` info-lints elsewhere; `main_corrupted.dart` errors are the known-dead file).
Debug APK built and installed on the real device for all testing above.

---

## 2026-07-20 — Claude — V4.5: move album favorites onto the native-mirror path too

Follow-up to the pivot below, per the user: "move everything (except collab) to the new
system please." Album favorites were the one dynamic-playlist source still on the old
pre-fetch-and-drive path (`getAlbumTracks` → `loadQueueAndPlay`). Added
`YouTubeService.getAlbumPlaylistId(album, artist)` (`youtube_service.dart`) — resolves the
album's own watch-playlist id (`OLAK5uy…`/`VL…`), preferring the header's PLAY/SHUFFLE button
via a new generic `_findAnyPlaylistId` recursive helper (falls back to searching the whole
browse response if the header doesn't have it). `main.dart`'s `_playFavorite` album branch now
tries `collab.playNativeMix(listId: albumPlaylistId)` first; if no id is found it falls back to
the old `getAlbumTracks`/`loadQueueAndPlay` path (unchanged, still there as a safety net).

Left on the collab-queue path deliberately (no native equivalent exists to move them to):
**artist "own songs" mode** (`getArtistTracks`, our own weighted-shuffle ordering — not
something YT Music exposes as a triggerable native list) and **Quick Picks** (a curated song
shelf, not a playlist id). Collab (passenger add-to-queue) stays app-driven per the earlier
`MediaController.addQueueItem`-doesn't-exist finding — this was explicitly excluded by the user
("except collab").

`puro flutter analyze` clean (only pre-existing `withOpacity` info-lints). Build + on-device
album-favorite test pending user confirmation.

**Reminder to self (per explicit user request this session): always add/update a STATUS.md
entry whenever code is added or changed, not just at natural stopping points.**

---

## 2026-07-20 — Claude — V4.5 pivot: passive native-queue mirror for dynamic playlists

Branch `V4.5`. Started from four V4 complaints (stale Supermix, janky car-control skips, MV/audio
dupes in dynamic playlists, no manual detach). Tactical fixes landed first (dedup, Supermix
deepen/shuffle+refresh, a `_detached` toggle, native push events + debounce, a restart-fallout
snapback for PREVIOUS-at-queue-start). On-device testing then showed the skip jank was structural:
every external NEXT still triggered a second, app-issued "reassert" transition racing YT Music's
own native skip. A follow-up attempt to own a second `MediaSession` to intercept car buttons
directly made this worse — destabilized YT Music's own session, caused a runaway queue-cycling
bug. That block was fully removed (see the VERDICT comment left in `MainActivity.kt` near where it
was — do not reintroduce a second active `MediaSession` in this app).

Pivoted per the user's suggestion instead of continuing to patch: **for dynamic playlists
(Supermix/mixes/artist radio), stop building our own queue — trigger the mix natively in YT Music
and just mirror its real queue for display.** Confirmed via `javap` on `android.jar` that
`MediaController.addQueueItem` doesn't exist on the framework class, so passenger/collab
"add to queue" **cannot** go through the same native path — collab keeps its existing app-driven
queue (`QueueSource.collab`), while everything else uses the new passive mirror
(`QueueSource.native`). Full architecture written up in the "🎵 Core Idea" section of `AGENTS.md`
(rewritten this session) — high level:
- New Kotlin handlers in `MainActivity.kt`: `playNativeMix` (builds a `watch?v=…&list=<mixId>` URI
  and calls `transportControls.playFromUri`), `nativeSkipNext/Previous/TogglePlayPause`,
  `nativeSkipToQueueItem`. `pushMediaEvent` (over the existing `media_events` `EventChannel`) now
  also dumps YT Music's live `controller.queue` (title/subtitle/iconUri/queueId) +
  `activeQueueItemId`, debounced 200ms to avoid exposing YT Music's mid-transition state.
- `DashboardProvider` (`main.dart`) parses that queue push, dedups by `queueId`, and keeps a capped
  history (`_nativeQueueHistory`, 100 items) of tracks that have left the live queue via a real
  active-item transition (not every reshuffle) — so scrolling up in the queue tab still shows what
  already played.
- `CollabService` gained `QueueSource` (`collab`/`native`), `playNativeMix()` (with a
  `_playViaIntent` cold-start fallback — this was the "Supermix button stopped working" bug),
  `nativeNext/Previous/TogglePlayPause/SkipToQueueItem` passthroughs. `_playMix()` and the
  artist-radio branch of `_playFavorite()` now call `playNativeMix` instead of pre-fetching tracks.
- `youtube_service.dart` trimmed: dead dedup/deepen-shuffle/continuation-token code removed;
  `getArtistRadioTracks` replaced by `getArtistRadioPlaylistId` (just returns the RD… id, no
  longer expands the whole tracklist itself); `getMixTracks` reduced to a one-liner (only still
  used for Quick Picks' pre-supplied `songs`).
- `queue_tab.dart`: the separate NATIVE/COLLAB pill (caused a pixel overflow) was removed — the
  existing collab wifi_tethering toggle now doubles as the source switch (on = collab queue, off =
  native mirror); the "QUEUE" badge next to the album art shows NATIVE/COLLAB dynamically instead.
  Added `_buildNativeQueueList` + `_nativeThumbnail` (native items now show real album art via the
  new `iconUri` field). Tapping any row, or a track auto-advancing, now calls `_followNowPlaying()`
  to recenter the scroll position. Header icon buttons (`_iconBtn`, queue tab) enlarged 36→48px,
  favorite buttons (`_favIconButton`, `main.dart`) enlarged to a 44×44 tap target — both for
  easier hits while driving.
- Play/pause icon flicker (`_MediaControlPanelState`) fixed with a 220ms debounce before the
  displayed icon follows a raw state flip.

**Verified on-device** (real S25+, wireless adb): mix trigger silently loads the full queue with
no YT Music UI flash; the mirrored list matches YT Music's real queue; car-button skips are now a
single clean transition (no more double-transition); Supermix cold-start fallback confirmed
working; duplicate-active-song-in-list bug fixed and held up over repeated skips.

**Not yet done:** none of this session's work is git-committed yet (only the original "V4.5:
Supermix refresh…" checkpoint commit exists) — commit once the user gives final go-ahead. Album
favorites still use the old pre-fetch-then-queue path (`getAlbumTracks` → `loadQueueAndPlay`,
unchanged) — only mixes/artist-radio moved to the native-mirror path this session; consider
whether albums should eventually move too (album browse doesn't have a native "mix id" equivalent
the same way, so this needs its own look, not assumed to be a copy-paste).

---

## 2026-07-20 — Claude — docs: split CLAUDE.md into AGENTS.md + STATUS.md + STATUS_ARCHIVE.md

Set up shared docs so Claude Code and Codex sessions can hand off work to each other.
`CLAUDE.md`'s content (all of it was project info, nothing Claude-Code-specific) moved to
`AGENTS.md` verbatim; `CLAUDE.md` is now a short pointer to `AGENTS.md`/`STATUS.md` (kept
so Claude Code still auto-loads it). Added this `STATUS.md` for task-entry logging and an
empty `STATUS_ARCHIVE.md` for overflow.

No code changes. Nothing else in flight from this session.
