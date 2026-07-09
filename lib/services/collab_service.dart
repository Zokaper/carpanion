import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_media_controller/flutter_media_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import 'youtube_service.dart';

/// App-level engine for the Collaborative Playback feature.
///
/// This lives for the whole app session (registered in `main.dart`'s
/// MultiProvider) so collab keeps running while the user is on another tab and
/// survives the collab view being disposed. It owns the socket, playback
/// control, the Auto-DJ that advances the queue, and persistence of the session
/// id / enabled flag / current index (the queue itself is persisted by
/// [YouTubeService]).
class CollabService extends ChangeNotifier {
  // Defaults to the hosted backend. Override for local testing with
  // --dart-define=BACKEND_URL=http://10.0.2.2:3000 (10.0.2.2 = host localhost from the emulator).
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: "https://carpanion.onrender.com",
  );
  static const String _sessionKey = 'collab_session_id';
  static const String _enabledKey = 'collab_enabled';
  static const String _indexKey = 'collab_index';

  final DashboardProvider _dashboard;
  final YouTubeService _yt;

  io.Socket? _socket;

  String _sessionId = '';
  bool _enabled = false; // "Collab enabled" = passenger sharing is open (NOT playback).
  int _currentPlayingIndex = -1;
  // True while we are actively driving the queue (so Auto-DJ advances at song end).
  // Decoupled from _enabled so favorites playback works with Collab off.
  bool _playbackActive = false;
  bool _allowEditing = false;
  bool _allowMediaControl = false;

  // Tracked to detect changes coming from DashboardProvider notifications.
  String _lastTrack = '';
  bool _lastPlaying = false;

  // True while an Auto-DJ advance is in flight (target track still loading in YT
  // Music), to prevent double-advancing past queue entries.
  bool _advancing = false;

  // One-shot timer that advances to the next queue item just before the current
  // track ends (rescheduled on each media poll from duration−position), so YT
  // Music never gets to autoplay its own next-up.
  Timer? _endAdvanceTimer;

  bool _initialized = false;

  CollabService(this._dashboard, this._yt) {
    _init();
  }

  // --- Public state for the UI ---
  String get sessionId => _sessionId;
  bool get enabled => _enabled;
  int get currentPlayingIndex => _currentPlayingIndex;

  /// True while OUR queue is actively driving playback (favorites or collab), so
  /// the UI can show a "playing from queue" indicator. False once the queue ends
  /// or the user plays something unrelated in YT Music.
  bool get playbackActive => _playbackActive;

  /// The album/track cover for the CURRENTLY PLAYING queue item — but only when
  /// the native now-playing track actually matches it. Lets the now-playing panel
  /// show OUR cover (e.g. the album cover) instead of YT Music's native art, which
  /// for an audio-swapped single reports the single's cover, not the album's.
  String? get currentTrackArt {
    if (!_playbackActive || _currentPlayingIndex < 0 || _currentPlayingIndex >= _yt.currentQueue.length) {
      return null;
    }
    final item = _yt.currentQueue[_currentPlayingIndex];
    final qTitle = (item['title'] ?? '').toString().toLowerCase();
    final native = _dashboard.currentTrack.toLowerCase();
    if (qTitle.isEmpty || native.isEmpty) return null;
    final matches = qTitle == native || qTitle.contains(native) || native.contains(qTitle);
    if (!matches) return null; // don't paint our cover over an unrelated track
    final thumb = (item['thumbnail'] ?? '').toString();
    return thumb.isNotEmpty ? thumb : null;
  }

  bool get allowEditing => _allowEditing;
  bool get allowMediaControl => _allowMediaControl;
  bool get isConnected => _socket?.connected == true;
  String get shareUrl => '$backendUrl/?session=$_sessionId';

  Future<void> _init() async {
    // Restore persisted collab state. The queue itself is restored by YouTubeService.
    try {
      final prefs = await SharedPreferences.getInstance();
      _sessionId = prefs.getString(_sessionKey) ?? '';
      if (_sessionId.isEmpty) {
        _sessionId = _generateSessionId();
        await prefs.setString(_sessionKey, _sessionId);
      }
      _enabled = prefs.getBool(_enabledKey) ?? false;
      _currentPlayingIndex = prefs.getInt(_indexKey) ?? -1;
    } catch (e) {
      debugPrint('CollabService: failed to load persisted state: $e');
      if (_sessionId.isEmpty) _sessionId = _generateSessionId();
    }

    _initialized = true;
    _lastTrack = _dashboard.currentTrack;
    _lastPlaying = _dashboard.isPlaying;

    // Wait for the persisted queue to finish restoring before reconciling, else
    // we match the now-playing title against an empty queue and lose the highlight
    // / Auto-DJ resume on a restart-mid-song.
    await _yt.queueReady;

    // Silent restore: we set _currentPlayingIndex from disk but do NOT replay it.
    // YT Music is likely still playing the song; if it matches a queue item,
    // reconcile the highlight to it now (no playback triggered) and resume Auto-DJ.
    final restoredIdx = _matchQueueIndex(_lastTrack);
    if (restoredIdx != -1) {
      _currentPlayingIndex = restoredIdx;
      _playbackActive = true;
    }

    _dashboard.addListener(_onDashboardUpdate);
    _yt.addListener(_onQueueUpdate);
    _connectSocket();
    notifyListeners();
  }

  String _generateSessionId() {
    final rand = Random();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(6, (index) => chars[rand.nextInt(chars.length)]).join();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, _sessionId);
      await prefs.setBool(_enabledKey, _enabled);
      await prefs.setInt(_indexKey, _currentPlayingIndex);
    } catch (e) {
      debugPrint('CollabService: failed to persist state: $e');
    }
  }

  // --- Socket lifecycle ---
  void _connectSocket() {
    _socket = io.io(backendUrl, io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .build());

    _socket!.clearListeners();
    _socket!.connect();

    _socket!.onConnect((_) {
      debugPrint("Collab: connected to backend, registering session: $_sessionId");
      _socket!.emit('register_session', _sessionId);
    });

    _socket!.on('add_song', (data) async {
      if (!_enabled) return; // passenger writes only when sharing is on
      debugPrint("Collab: add_song event: $data");
      if (data is Map && data['videoId'] != null) {
        final ok = await _yt.addVideoToPlaylist(
          data['videoId'],
          title: data['title'] ?? '',
        );
        if (ok) _maybeAutoStart();
      }
    });

    _socket!.on('passenger_add_resolved', (data) async {
      if (!_enabled) return;
      // A song the passenger picked from the PWA's YT Music search list — already
      // resolved to an exact songId, so add it directly (no re-search).
      debugPrint("Collab: passenger_add_resolved event: $data");
      if (data is Map && data['videoId'] != null) {
        final ok = await _yt.addResolvedSong(
          videoId: data['videoId'].toString(),
          title: (data['title'] ?? '').toString(),
          artist: (data['artist'] ?? '').toString(),
          thumbnail: (data['thumbnail'] ?? '').toString(),
        );
        if (ok) _maybeAutoStart();
      }
    });

    _socket!.on('passenger_search_and_add_song', (query) async {
      if (!_enabled) return;
      debugPrint("Collab: passenger_search_and_add_song event: $query");
      final ok = await _yt.searchAndAddSong(query.toString());
      if (ok) _maybeAutoStart();
    });

    _socket!.on('request_queue', (_) {
      _socket!.emit('update_queue', jsonEncode(_yt.currentQueue));
    });

    _socket!.on('request_permissions', (_) {
      _socket!.emit('update_permissions', _allowEditing);
      _socket!.emit('update_media_permissions', _allowMediaControl);
      _socket!.emit('update_play_state', _dashboard.isPlaying);
    });

    _socket!.on('request_search', (data) async {
      if (data is! Map) return;
      final passengerId = data['passengerId'];
      final query = (data['query'] ?? '').toString();
      final source = (data['source'] ?? 'ytmusic').toString();

      List<Map<String, dynamic>> results;
      if (source == 'youtube') {
        // Demo/unreleased search via the YouTube Data API.
        results = await _yt.searchSongs(query);
      } else {
        // Default: YT Music song search — clean, well-ranked results.
        final songs = await _yt.searchYTMusicSongs(query);
        results = songs
            .map((s) => {
                  'videoId': s['videoId'],
                  'title': s['title'],
                  'channel': s['artist'],
                  'thumbnail': s['thumbnail'],
                  'resolved': true, // exact songId — PWA adds directly
                })
            .toList();
      }
      _socket!.emit('search_results', {
        'passengerId': passengerId,
        'results': results,
      });
    });

    _socket!.on('passenger_media_action', (action) async {
      if (!_enabled || !_allowMediaControl) return;
      try {
        if (action == 'playPause') {
          await FlutterMediaController.togglePlayPause();
        } else if (action == 'next') {
          next();
        } else if (action == 'previous') {
          previous();
        }
      } catch (e) {
        debugPrint("Collab: media action error: $e");
      }
    });

    _socket!.on('passenger_play_song', (id) async {
      if (!_enabled || !_allowMediaControl) return;
      final index = _yt.currentQueue.indexWhere((item) => item['id'] == id);
      if (index != -1) playAt(index);
    });

    _socket!.on('passenger_delete_song', (playlistItemId) async {
      if (_enabled && _allowEditing) await _yt.deleteSong(playlistItemId);
    });

    _socket!.on('passenger_reorder_song', (data) async {
      if (_enabled && _allowEditing && data is Map) {
        await _yt.reorderSong(data['playlistItemId'], data['newPosition']);
      }
    });

    _socket!.onDisconnect((_) => debugPrint('Collab: disconnected from backend'));
  }

  // --- Queue → passengers sync ---
  void _onQueueUpdate() {
    if (_socket?.connected == true) {
      _socket!.emit('update_queue', jsonEncode(_yt.currentQueue));
    }
  }

  // --- Auto-DJ + now-playing / play-state sync ---
  void _onDashboardUpdate() {
    if (!_initialized) return;

    // Sync play/pause state to passengers whenever it changes.
    if (_dashboard.isPlaying != _lastPlaying) {
      _lastPlaying = _dashboard.isPlaying;
      _socket?.emit('update_play_state', _lastPlaying);
    }

    // Runs on every tick (incl. position-only updates) — must be before the
    // unchanged-track early-return below.
    _scheduleEndAdvance();

    if (_dashboard.currentTrack == _lastTrack) return;
    _lastTrack = _dashboard.currentTrack;
    _socket?.emit('update_playing_status', _lastTrack);

    // Auto-DJ runs whenever we are actively driving the queue (favorites OR collab),
    // independent of the sharing flag.
    final index = _matchQueueIndex(_lastTrack);
    if (index != -1) {
      // Our advance target loaded — safe to advance again on the next song-end.
      _advancing = false;
      // Keep the highlight synced with whatever queue track is playing.
      if (_currentPlayingIndex != index) {
        _currentPlayingIndex = index;
        _persist();
      }
    } else if (_playbackActive && _currentPlayingIndex != -1 && !_advancing) {
      // A non-queue track appeared while we're driving the queue — either our track
      // ended (YT Music autoplayed its own next-up) OR an external controller (car /
      // Bluetooth / notification) skipped inside YT Music. These are INDISTINGUISHABLE
      // from here: verified on-device (2026-07-09) that YT Music never emits
      // STATE_SKIPPING_TO_NEXT/PREVIOUS, and the system media-key APIs need the
      // privileged MEDIA_CONTENT_CONTROL permission we can't hold — so an external
      // skip looks exactly like a deliberate track change. Per product decision the
      // queue is authoritative: advance to our next item so an external skip never
      // "loses" the queue. playAt() re-arms _advancing while YT Music loads the
      // target, so autoplay flashing non-matching tracks can't skip entries.
      if (_yt.currentQueue.length > _currentPlayingIndex + 1) {
        _currentPlayingIndex++;
        debugPrint("Collab Auto-DJ: reasserting queue → index $_currentPlayingIndex");
        playAt(_currentPlayingIndex);
      } else {
        // End of queue — nothing to advance to. Release so we don't fight YT Music's
        // post-queue radio. (Re-arm by tapping a queue row / favorite; hard reset via
        // Clear Queue / New Session.)
        _currentPlayingIndex = -1;
        _playbackActive = false;
        _persist();
      }
    }
    notifyListeners();
  }

  /// (Re)schedule a precise one-shot advance to fire just before the current
  /// queue track ends — polling for "near the end" misses the window (YT Music
  /// autoplays its next-up between our ~1s polls), so we compute the exact time
  /// remaining and schedule a timer, cancelling/rescheduling on each poll.
  void _scheduleEndAdvance() {
    _endAdvanceTimer?.cancel();
    if (!_playbackActive || _advancing || !_dashboard.isPlaying) return;
    if (_currentPlayingIndex < 0 || _currentPlayingIndex + 1 >= _yt.currentQueue.length) return;
    // NOTE: mediaPosition/mediaDuration are in MILLISECONDS.
    final durMs = _dashboard.mediaDuration;
    final posMs = _dashboard.mediaPosition;
    if (durMs <= 5000 || posMs < 0) return; // ignore bad/short values
    // Fire a bit before the true end; YT Music's ~0.5-1s load latency then masks
    // the gap so the next track starts right as the current one finishes.
    const leadMs = 1200;
    final remainingMs = (durMs - posMs - leadMs).round();
    if (remainingMs < 0) return; // already inside the lead window; reactive covers it
    _endAdvanceTimer = Timer(Duration(milliseconds: remainingMs), () {
      if (!_playbackActive || _advancing || !_dashboard.isPlaying) return;
      if (_currentPlayingIndex < 0 || _currentPlayingIndex + 1 >= _yt.currentQueue.length) return;
      _currentPlayingIndex++;
      debugPrint("Collab Auto-DJ: timed advance to index $_currentPlayingIndex");
      playAt(_currentPlayingIndex);
    });
  }

  int _matchQueueIndex(String track) {
    final dTitle = track.toLowerCase();
    if (dTitle.isEmpty) return -1;
    return _yt.currentQueue.indexWhere((item) {
      final qTitle = (item['title'] ?? '').toString().toLowerCase();
      return qTitle == dTitle || qTitle.contains(dTitle) || dTitle.contains(qTitle);
    });
  }

  /// Auto-start playback when a song is added to an idle queue (nothing playing).
  void _maybeAutoStart() {
    if (!_playbackActive && _currentPlayingIndex == -1 && _yt.currentQueue.isNotEmpty) {
      playAt(0);
    }
  }

  // --- Favorites playback entry points (replace the queue and play "now") ---

  /// Plays a single favorited song directly (no YT Music flash).
  Future<void> playFavoriteSong({
    required String videoId,
    required String title,
    String artist = '',
    String thumbnail = '',
  }) async {
    await _yt.replaceQueue([
      {'videoId': videoId, 'title': title, 'artist': artist, 'thumbnail': thumbnail},
    ]);
    playAt(0);
  }

  /// Replaces the queue with a resolved track list (album tracks / artist radio)
  /// and starts playing from the top. When [resolveAudio] is set (albums), the
  /// video (OMV) ids YT Music hands out for tracks with a music video are swapped
  /// for the audio-only (ATV) version — the first track before it plays, the rest
  /// in the background — so albums play audio instead of the music video.
  Future<void> loadQueueAndPlay(List<Map<String, String>> songs, {bool resolveAudio = false}) async {
    if (songs.isEmpty) return;
    await _yt.replaceQueue(songs);
    if (resolveAudio) {
      // Resolve just the first track up front (bounded ~3s) so playback starts on
      // audio without a restart; if it's slow we start anyway and the background
      // pass fixes it. The rest are swapped lazily in the background.
      try {
        await _resolveQueueItemAudio(0).timeout(const Duration(seconds: 3));
      } catch (_) {/* start now; background pass will catch index 0 */}
    }
    playAt(0);
    if (resolveAudio) {
      _resolveQueueAudioInBackground(); // fire-and-forget
    }
  }

  /// Re-resolves a single queue item to its audio version if it's a video track.
  /// Returns true if the id changed. Guards against the queue being replaced mid-flight.
  Future<bool> _resolveQueueItemAudio(int index) async {
    final queue = _yt.currentQueue;
    if (index < 0 || index >= queue.length) return false;
    final item = queue[index];
    final vt = (item['videoType'] ?? '').toString();
    if (vt.isEmpty || vt.contains('ATV')) return false; // already audio / unknown
    final title = (item['title'] ?? '').toString();
    final artist = (item['artist'] ?? '').toString();
    final id = (item['id'] ?? '').toString();
    final audioId = await _yt.resolveAudioVideoId(title, artist);
    // Bail if the queue changed under us (different item now at this index).
    if (index >= _yt.currentQueue.length || (_yt.currentQueue[index]['id'] ?? '') != id) return false;
    if (audioId == null) {
      _yt.currentQueue[index]['videoType'] = 'MUSIC_VIDEO_TYPE_ATV'; // don't retry
      return false;
    }
    final changed = audioId != _yt.currentQueue[index]['videoId'];
    await _yt.setQueueItemVideoId(index, audioId);
    if (changed) debugPrint('Collab: swapped track $index "$title" video→audio ($audioId)');
    return changed;
  }

  /// Background swap of the remaining video tracks (bounded concurrency to stay
  /// gentle on YT Music's anonymous API). Restarts the current track as audio if
  /// its id changes while it's playing.
  Future<void> _resolveQueueAudioInBackground() async {
    final targets = <int>[];
    for (int i = 0; i < _yt.currentQueue.length; i++) {
      final vt = (_yt.currentQueue[i]['videoType'] ?? '').toString();
      if (vt.isNotEmpty && !vt.contains('ATV')) targets.add(i);
    }
    if (targets.isEmpty) return;

    int next = 0;
    Future<void> worker() async {
      while (true) {
        final k = next++;
        if (k >= targets.length) break;
        final i = targets[k];
        final changed = await _resolveQueueItemAudio(i);
        // If we just fixed the track that's playing right now, restart it as audio.
        if (changed && i == _currentPlayingIndex && _playbackActive) {
          playAt(i);
        }
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
    _onQueueUpdate(); // push the audio-swapped queue to passengers
  }

  // --- Enable / Disable — sharing layer only, never touches playback ---
  void enable() {
    _enabled = true;
    _persist();
    notifyListeners();
    // Re-broadcast current state to any connected passengers.
    _socket?.emit('update_queue', jsonEncode(_yt.currentQueue));
    _socket?.emit('update_permissions', _allowEditing);
    _socket?.emit('update_media_permissions', _allowMediaControl);
  }

  void disable() {
    // Close the door to passengers. Playback is untouched and keeps going.
    _enabled = false;
    _persist();
    notifyListeners();
  }

  // --- Media controls ---
  void next() {
    if (_currentPlayingIndex != -1 && _yt.currentQueue.length > _currentPlayingIndex + 1) {
      playAt(_currentPlayingIndex + 1);
    } else {
      FlutterMediaController.nextTrack();
    }
  }

  void previous() {
    if (_currentPlayingIndex > 0) {
      playAt(_currentPlayingIndex - 1);
    } else {
      FlutterMediaController.previousTrack();
    }
  }

  /// Plays the queue item at [index] via YT Music's MediaSession (no UI flash),
  /// falling back to a launch intent if the session isn't reachable.
  void playAt(int index) {
    if (index < 0 || index >= _yt.currentQueue.length) return;
    _currentPlayingIndex = index;
    _playbackActive = true;
    // Guard Auto-DJ from advancing off this track until YT Music actually loads
    // it. Right after a deliberate play the native metadata still reports the
    // PREVIOUS song (which isn't in the new queue), and without this the Auto-DJ
    // would instantly skip to index+1. Cleared when `_matchQueueIndex` sees the
    // target load; self-heals after 10s if it never does.
    _advancing = true;
    Future.delayed(const Duration(seconds: 10), () => _advancing = false);
    _persist();
    notifyListeners();

    final item = _yt.currentQueue[index];
    final videoId = item['videoId']?.toString();
    final query = '${item['title']} ${item['artist']}';

    DashboardProvider.platform.invokeMethod('playFromMediaSession', {
      'videoId': videoId,
      'query': query,
    }).then((result) {
      final success = result is Map && result['success'] == true;
      if (success) {
        debugPrint("Collab: playing via MediaSession (${result['method']}): $query");
      } else {
        debugPrint("Collab: MediaSession failed, falling back to intent");
        _playViaIntent(query, videoId: videoId);
      }
    }).catchError((e) {
      debugPrint("Collab: MediaSession error: $e, falling back to intent");
      _playViaIntent(query, videoId: videoId);
    });
  }

  void _playViaIntent(String query, {String? videoId}) {
    // Prefer the EXACT track by its watch URL. A search intent (the old fallback)
    // resolves to whatever YT Music ranks first — often the wrong song or a video
    // version — which is why a cold-start album could open on the wrong track.
    final AndroidIntent intent;
    if (videoId != null && videoId.isNotEmpty) {
      intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'https://music.youtube.com/watch?v=$videoId',
        package: 'com.google.android.apps.youtube.music',
      );
    } else {
      intent = AndroidIntent(
        action: 'android.media.action.MEDIA_PLAY_FROM_SEARCH',
        arguments: <String, dynamic>{'query': query},
        package: 'com.google.android.apps.youtube.music',
      );
    }
    intent.launch().catchError((e) {
      debugPrint("Collab: could not launch targeted YT Music intent: $e");
    });

    _dashboard.setWaitingForMusic();

    // Pull the Dashboard back to the front after the intent launches YT Music.
    Future.delayed(const Duration(seconds: 2), () {
      final backIntent = AndroidIntent(
        action: 'action_main',
        package: 'com.example.car_dashboard',
        componentName: 'com.example.car_dashboard.MainActivity',
        flags: [268435456, 131072], // NEW_TASK | REORDER_TO_FRONT
      );
      backIntent.launch().catchError((e) => debugPrint("Collab: could not reorder Dashboard to front: $e"));
    });
  }

  // --- Permissions ---
  void setAllowEditing(bool value) {
    _allowEditing = value;
    _socket?.emit('update_permissions', _allowEditing);
    notifyListeners();
  }

  void setAllowMediaControl(bool value) {
    _allowMediaControl = value;
    _socket?.emit('update_media_permissions', _allowMediaControl);
    notifyListeners();
  }

  /// Empties the queue but keeps the current session. Resets the playing index
  /// so a later add auto-starts correctly.
  Future<void> clearQueue() async {
    _currentPlayingIndex = -1;
    _playbackActive = false;
    await _yt.clearPlaylist();
    await _persist();
    notifyListeners();
  }

  // --- Session reset (the ONLY full reset path) ---
  Future<void> newSession() async {
    _sessionId = _generateSessionId();
    _currentPlayingIndex = -1;
    _playbackActive = false;
    _enabled = false;
    await _yt.clearPlaylist();
    await _persist();

    // Re-register the fresh session on the existing socket.
    if (_socket?.connected == true) {
      _socket!.emit('register_session', _sessionId);
      _socket!.emit('update_queue', jsonEncode(_yt.currentQueue));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _dashboard.removeListener(_onDashboardUpdate);
    _yt.removeListener(_onQueueUpdate);
    _socket?.clearListeners();
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }
}
