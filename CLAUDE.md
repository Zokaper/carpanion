# Developer Guide (CLAUDE.md)

This file contains build commands, development guidelines, and context about the ongoing implementation of the Collaborative Playback (Collab) feature for Carpanion.

---

## 🛠️ Build & Run Commands

This project uses `puro` for Flutter version management. Always use the `puro` wrapper when executing Flutter commands.

### Development Commands
* **Run App**: `puro flutter run`
* **Run App on Specific Device**: `puro flutter run -d <device-id>`
* **Hot Reload**: Press `r` in the terminal running the app.
* **Hot Restart**: Press `R` in the terminal running the app.
* **Clean Build**: `puro flutter clean`
* **Get Dependencies**: `puro flutter pub get`

### Backend Server Commands
The backend server coordinates the passenger-facing PWA and WebSocket communication.
* **Path**: `a:\Antigravity Projects\carpanion\backend`
* **Start Server**: `node server.js`

---

## 📐 Coding Guidelines & Architecture

### Styling & Layout
* Use Vanilla CSS/Flutter styling. Do not introduce tailwind-like utility paradigms unless specified.
* UI components follow a rich, custom glassmorphic aesthetic optimized for readability in a vehicle dashboard context (supports Day/Evening/Night HSL-lerp transitions).

### Communication Channels
* **Dart-to-Kotlin**: Exposes a platform channel `com.example.car_dashboard/system` in `MainActivity.kt`.
* **Passenger-to-Dashboard**: Real-time WebSockets (`socket.io`). Passengers connect to the local node server's PWA by scanning a QR code on the tablet dashboard screen.

---

## 🎵 Collaborative Playback (Collab Feature) State

We are currently implementing the **Collab Feature** (allowing passengers to add/remove/edit the queue for YouTube Music via a PWA).

### What We Tried & Found:
1. **Activity Intents (Approach 1/2)**: Launching `MEDIA_PLAY_FROM_SEARCH` intents directly caused YouTube Music to flash to the foreground on every song change, interrupting the Dashboard UI.
2. **MediaSession Manager (Approach 3 - Active)**:
   - Reused `MediaSessionManager` / `DashcamListenerService.kt` to target the active session of `com.google.android.apps.youtube.music`.
   - Determined that YT Music's MediaSession supports `PLAY_FROM_SEARCH`, `PLAY_FROM_URI`, `PREPARE_FROM_SEARCH`, and `PREPARE_FROM_URI`.
   - **`playFromSearch` fails** (accepted but silently ignored by YT Music).
   - **`playFromUri` works successfully** without flashing the YT Music app to the foreground.

### The Audio vs. Video Problem & Song Resolution
* **The issue**: Directly playing YouTube video URLs via `playFromUri` often plays the video version of a track (which can contain long movie monologues, different mixes, or affect music tracking/scrobbling).
* **The solution**: We introduced `_resolveYTMusicSongId` in `youtube_service.dart`. This function queries YT Music's Web/Innertube API search endpoint with a **Songs-only filter** to resolve the correct, audio-only version's video ID before adding the song to the queue.

---

## 🚨 Current Task & Unfinished Prompt

We are currently debugging the **YT Music Song Resolution** matching logic. The Innertube search returns song results, but it is matching incorrect titles or completely unrelated songs.

Here is the user's unfinished context/logs detailing the problem:

```text
Received passenger_search_and_add_song event: Freak Lana Del Rey
YT Music resolved "The Abyss The Weeknd & Lana Del Rey" → song ID: kbZoNHhfhHo
Queue: Using YT Music song ID (kbZoNHhfhHo) instead of video ID (TWjM9cBiCcs) for "The Abyss"
D/Carpanion: playFromUri sent to YT Music: https://music.youtube.com/watch?v=kbZoNHhfhHo
Collab: Playing via MediaSession (playFromUri): The Abyss The Weeknd & Lana Del Rey  

Received add_song event: {videoId: Py_-3di1yx0, title: }
YT Music resolved "My Harf Is Unknown Yang Su Hyeok" → song ID: YD_Pa2oap80
Queue: Using original video ID (Py_-3di1yx0) for "My Harf Is Unknown" (song ID resolution failed) or it played "My Harf Is Unknown"
```

### Problems to address:
1. **Title/Artist Mismatch**: Why did searching "Freak Lana Del Rey" resolve to "The Abyss"? Why did `add_song` with `Py_-3di1yx0` get resolved to "My Harf Is Unknown"?
2. **Search API Quality**: The `_resolveYTMusicSongId` query is constructed as `title artist`. We need to inspect the Innertube API request payload, the parameters `EgWKAQIIAWoKEAkQBRAKEAMQBA==`, and verify the parse logic to ensure it extracts the closest match (or the exact top result).
3. **No-Title Payload**: In `add_song`, the payload is sometimes `{videoId: ..., title: ""}`. We need to handle cases where the title/artist metadata is empty or missing, ensuring we look up the original YouTube video title first before searching YT Music.
