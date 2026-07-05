# Project Memory: Car Dashboard Infotainment Hub

This file serves as a memory/context document for developers and AI assistants (like Gemini) working on this codebase. It outlines the application’s design, architecture, custom native components, and recent updates.

---

## 🚗 Project Overview
This is a Flutter-based custom Car Dashboard (infotainment/carputer UI) designed to run on an Android device (like a tablet or head unit) mounted in a vehicle. It consolidates driving metrics, maps/navigation automation, media launching, phone controls, notification tracking, and system settings into a unified, glassmorphic UI.

---

## 🏗️ Architecture & Core Components

### 1. Flutter UI & State Management
* **`lib/main.dart`**: The main entry point. Houses the `DashboardProvider` which coordinates states like GPS speed, theme, media progress, active notification indicators, welcome UI visibility, network status, brightness, and ringer modes.
* **`lib/theme/dynamic_theme.dart`**: Implements a time-sensitive theme system. Smoothly transitions between **Day**, **Evening**, and **Night** themes using HSL-lerping. Contains a specific contrast adjustment: it dips (darkens) the primary color during transition phases to ensure optimal readability against grey card backgrounds.
* **`lib/speedometer_widget.dart`**: A highly stylized custom-painted speedometer gauge:
  * Uses a `_SpeedGaugePainter` with a sweep gradient to visually depict orange warning and red danger/redline zones on the gauge track.
  * Shows GPS accuracy in meters accompanied by a cellular-strength-bar style color-coded signal visualizer.
  * Prompts a confirmation dialog before stopping dashcam recording to prevent accidental taps.

### 2. Welcome Overlay (Driving Automation)
* **`lib/ui/welcome_overlay.dart`**: A beautiful glassmorphic startup overlay ("Ready to drive?"):
  * Stages a Google Maps destination and a YouTube Music search term/playlist.
  * Launches navigation and waits for active navigation to start (via ongoing Maps notification detection).
  * Automatically pulls the dashboard app back to the foreground (`bringToFront`) after navigation launches so the user sees the dashboard while driving.
  * Starts YouTube Music in the background and launches Droid Dashcam recording.

### 3. Native Android Platform Channel (`MainActivity.kt`)
Exposes a `com.example.car_dashboard/system` channel with native APIs:
* **`startDashcam` / `stopDashcam`**: Sends explicit intents to start/stop recording on Helge's Droid Dashcam app (`com.helge.droiddashcam`).
* **`getBrightnessInfo` / `setSystemBrightness`**: Sets the system screen brightness value (requires `WRITE_SETTINGS` permission, which it triggers if missing).
* **`getRingerMode` / `setRingerMode`**: Queries and updates system sound profile (Normal, Vibrate, Silent) via AudioManager.
* **`getNetworkStatus`**: Fetches active network type, Wi-Fi level (0–4 bars), and Cellular signal strength level.
* **`isNavigating`**: Inquires if Google Maps is actively navigating.
* **`bringToFront`**: Programmatically brings the dashboard activity to the foreground.

### 4. Background Services & Notification Tracking
* **`DashcamListenerService.kt`**: An Android `NotificationListenerService` that plays a crucial role:
  * **Recording Detection**: Inspects notifications from `com.helge.droiddashcam` for active chronometers or "REC"/"Record" text flags to determine if the dashcam is running.
  * **Navigation Detection**: Detects if Google Maps is running in active navigation mode by checking for ongoing (`FLAG_ONGOING_EVENT`) notifications.
  * **Chat History Caching**: When chat notifications arrive (e.g. WhatsApp, Telegram), it parses `Notification.EXTRA_MESSAGES` or `Notification.EXTRA_TEXT_LINES`. Instead of letting new incoming messages overwrite the old ones, it caches and appends them, building a local message history. It only purges a chat log when the system notification itself is cleared.
* **`lib/ui/notifications_tab.dart`**: Displays notifications and active chats. 
  * Allows "tracking" a specific chat. Tracking is anchored to the notification's static native `key` (rather than dynamic titles which change with unread counts), ensuring that incoming messages are reliably associated with the correct thread.

---

## ⚡ Recent Changes Summary

1. **Robust Dashcam Tracking**: Refined `DashcamListenerService.kt` to check the chronometer and exact text keywords of Droid Dashcam notifications, fixing issues where the recording state wasn't detected correctly or would persist after recording stopped.
2. **Notification History & Message Merging**: Implemented Kotlin-side caching in `DashcamListenerService.kt`. The app now retains previously received messages and appends new ones to the active notification map, preventing message loss.
3. **Key-Based Chat Tracking**: Changed the chat tracker in `notifications_tab.dart` from matching on titles to matching on notification keys. This prevents the tracking feed from breaking when a notification title changes (e.g., when adding a count like "Chat (3 messages)").
4. **Network & Volume Indicators**: Added native code to fetch Wi-Fi and Cellular signal strength. Wired these to a new `CellularIconWidget` and status indicators in the dashboard header. Tapping the volume icon toggles between Ringer modes.
5. **Thick Brightness Slider**: Replaced default slider UI with a thick custom gesture-based track slider supporting quick auto/adaptive brightness toggling.
6. **Gauge Redlines & Confirmation**: Added redline sweep gradients to the speedometer gauge and a confirmation popup when stopping the dashcam.

---

## 🛠️ Next Steps & Roadmap
* [ ] Verify the auto-foregrounding behavior on the target Android tablet.
* [ ] Integrate Bluetooth connection listener triggers to auto-launch the Welcome overlay.
* [ ] Cache the tracked chat histories in local preferences (`SharedPreferences`) so they survive application restarts.
