# Local Testing (laptop) — dashboard + passenger PWA

A reproducible way to exercise the **V3 Favorites overhaul** and the **Collab** feature on
this Windows laptop, without the real tablet/phone. The dashboard runs on the **Android
emulator**; the backend + passenger PWA run **locally** via Node.

## What you CAN vs CAN'T test here

**Testable locally (no phone needed):**
- Typed favorites: add/remove song • album • artist, and persistence across restart (`fav_json`).
- Queue: add / dedup / reorder / delete.
- Collab round-trip: QR/session join, and every passenger action relayed to the dashboard and
  broadcast back to the PWA (add, tap-to-play, media buttons, delete, reorder).
- Permission gating: `COLLAB ON/OFF`, allow-editing, allow-media-control.
- PWA search (relayed to the dashboard, which resolves via YT Music Innertube over HTTP).
- The now-playing highlight on an **explicit** play / tap-to-play (index is app-managed).

**NOT reproducible without the phone (expected, not bugs):**
- Real audio. On the emulator YT Music isn't installed, so `playFromMediaSession` fails and
  falls back to a launch intent — **no sound plays**.
- **Auto-advance when a song ends** and highlight auto-tracking — these are driven by native
  now-playing polling, which returns nothing on the emulator.

> To unlock real audio later, install + sign into YT Music on a **Play Store** emulator image
> (see "Enabling real audio" at the bottom).

---

## One-time setup (already done)
- **Node.js** installed (`node -v` → v24.x). `backend/node_modules` present.
- **`lib/services/collab_service.dart`** `backendUrl` now reads
  `--dart-define=BACKEND_URL=...`, defaulting to the hosted `https://carpanion.onrender.com`.
- **`android/app/src/main/res/xml/network_security_config.xml`** allows cleartext (http/ws) to
  `10.0.2.2` / `localhost` only, referenced from `AndroidManifest.xml`. Production TLS path is
  unchanged. This is required because the emulator talks to the local backend over plain http.

## Run it (every session)

**1. Start the backend** (serves relay + PWA on port 3000):
```powershell
.\scripts\start-backend.ps1
```
Leave it running. It prints `Server running on port 3000`.

**2. Run the dashboard on the emulator**, pointed at the local backend:
```powershell
.\scripts\run-dashboard.ps1
```
This launches the `dev_phone` emulator if needed and runs with
`--dart-define=BACKEND_URL=http://10.0.2.2:3000` (`10.0.2.2` = the host's localhost from inside
the emulator). Equivalent manual command:
```powershell
puro flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000
```

> **No auth needed for Collab.** The Collab/queue tab has **no Google sign-in gate** — its
> mechanics (queue ops, YT Music Innertube search/resolve, native playback) are all anonymous.
> Google sign-in is **optional** and only powers the passenger "search YouTube for demos" toggle;
> it lives in **Settings → Media & Collab**. (The old `DEV_BYPASS_AUTH` dart-define is gone — there
> is no gate left to bypass. To test *real* Google sign-in, add a Google account to the emulator and
> register this machine's debug-keystore SHA-1 in your Google Cloud Console OAuth client, then use
> the SIGN IN button in Settings.)

**3. Open the passenger PWA** in Chrome on the laptop:
- In the app, open the **Collab / Queue** tab and tap **COLLAB ON**. Note the **session code**
  (shown as `Session: XXXXXX`, and encoded in the QR).
- Browse to: `http://localhost:3000/?session=XXXXXX` (use the code from the app).

You now have the dashboard (emulator) and a "passenger" (Chrome) on the same local relay.

> Tip: the speedometer needs GPS motion — the emulator's GPS is static. Toggle **Demo Mode**
> (Settings dialog) to simulate speed/GPS.

---

## Emulator: exact S25+ match (for layout checks)

Layout must be validated at the **real device's** logical size or findings are noise.
An AVD named **`S25plus`** was created to match the Samsung Galaxy S25+:
**1080×2340 @ 450 dpi** → landscape **2340×1080 (~832×384 dp)**. `run-dashboard.ps1`
defaults to it. The old `dev_phone` AVD (320×640) produced false overflow warnings — do
not use it for layout work.

To recreate the AVD if needed (avdmanager requires a JDK, e.g. Android Studio's):
```powershell
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
$avdm = "$env:LOCALAPPDATA\Android\Sdk\cmdline-tools\latest\bin\avdmanager.bat"
echo no | & $avdm create avd -n S25plus -k "system-images;android-34;google_apis;x86_64" -d pixel_6 --force
# then in %USERPROFILE%\.android\avd\S25plus.avd\config.ini set:
#   hw.lcd.width=1080  hw.lcd.height=2340  hw.lcd.density=450  hw.initialOrientation=landscape
```
> Note: this matches the S25+ **default** (FHD+ / standard screen-zoom → ~832 dp wide
> landscape). If your phone runs a different resolution/zoom, read its exact values with
> `adb shell wm size` + `wm density` and adjust `hw.lcd.*` to match precisely.

## Verify end-to-end
- **Backend up:** `curl http://localhost:3000/` returns the PWA HTML (title "Carpanion Queue").
  The server log shows `register_session` (dashboard connects) then `join_passenger` (PWA opens).
- **Collab:** from the PWA, add a song → it appears in the dashboard queue **and** re-broadcasts
  to the PWA. Reorder / delete from the PWA → reflected on the dashboard. Toggle a permission off
  on the dashboard → the passenger write is rejected.
- **Favorites:** favorite a song/album/artist → still present after an app restart. Tapping a
  favorite replaces the queue (album/artist fetch via Innertube — watch the run logs for
  `getAlbumTracks: … → N tracks`).
- **Expected non-results:** tapping play produces no audio and the highlight won't auto-advance.

---

## Enabling real audio (optional, later)
The current `dev_phone` AVD is a `google_apis` image (Play Services, **no Play Store**).
To get real playback + auto-advance:
1. Install a Play Store image and make an AVD:
   `sdkmanager "system-images;android-34;google_apis_playstore;x86_64"`, then create the AVD in
   Android Studio (Device Manager → the image with the Play Store icon).
2. Boot it, open the Play Store, install **YouTube Music**, sign in.
3. Run the dashboard on that emulator (same `--dart-define`). `playFromMediaSession` will drive
   YT Music for real. `adb` is at `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`.
   (Alternative: `adb install` a YT Music APK onto the existing `dev_phone` — sign-in works via
   Play Services but is flakier on a non-Play-Store image.)
