# Status log

Recent/active work, newest entry on top. One entry per chunk of work — what changed, why,
and what's left/next if anything. Standing project info (architecture, how things work)
belongs in `AGENTS.md`, not here. When this file gets long, move older entries into
`STATUS_ARCHIVE.md` (keep the newest ~10-15 entries here).

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
