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
  static const String backendUrl = "https://carpanion.onrender.com";
  static const String _sessionKey = 'collab_session_id';
  static const String _enabledKey = 'collab_enabled';
  static const String _indexKey = 'collab_index';

  final DashboardProvider _dashboard;
  final YouTubeService _yt;

  io.Socket? _socket;

  String _sessionId = '';
  bool _enabled = false;
  int _currentPlayingIndex = -1;
  bool _allowEditing = false;
  bool _allowMediaControl = false;

  // Tracked to detect changes coming from DashboardProvider notifications.
  String _lastTrack = '';
  bool _lastPlaying = false;

  bool _initialized = false;

  CollabService(this._dashboard, this._yt) {
    _init();
  }

  // --- Public state for the UI ---
  String get sessionId => _sessionId;
  bool get enabled => _enabled;
  int get currentPlayingIndex => _currentPlayingIndex;
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

    // Silent restore: we set _currentPlayingIndex from disk but do NOT replay it.
    // YT Music is likely still playing the song; if it matches a queue item,
    // reconcile the highlight to it now (no playback triggered).
    final restoredIdx = _matchQueueIndex(_lastTrack);
    if (restoredIdx != -1) _currentPlayingIndex = restoredIdx;

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
      if (!_allowMediaControl) return;
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
      if (!_allowMediaControl) return;
      final index = _yt.currentQueue.indexWhere((item) => item['id'] == id);
      if (index != -1) playAt(index);
    });

    _socket!.on('passenger_delete_song', (playlistItemId) async {
      if (_allowEditing) await _yt.deleteSong(playlistItemId);
    });

    _socket!.on('passenger_reorder_song', (data) async {
      if (_allowEditing && data is Map) {
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

    if (_dashboard.currentTrack == _lastTrack) return;
    _lastTrack = _dashboard.currentTrack;
    _socket?.emit('update_playing_status', _lastTrack);

    if (_enabled) {
      final index = _matchQueueIndex(_lastTrack);
      if (index != -1) {
        _currentPlayingIndex = index;
        _persist();
      } else {
        // YT Music moved to a track not in our queue (song ended / autoplay).
        if (_currentPlayingIndex != -1 && _yt.currentQueue.length > _currentPlayingIndex + 1) {
          _currentPlayingIndex++;
          debugPrint("Collab Auto-DJ: advancing to index $_currentPlayingIndex");
          playAt(_currentPlayingIndex);
        } else if (_currentPlayingIndex != -1) {
          _currentPlayingIndex = -1; // Reached the end of the queue.
          _persist();
        }
      }
    }
    notifyListeners();
  }

  int _matchQueueIndex(String track) {
    final dTitle = track.toLowerCase();
    if (dTitle.isEmpty) return -1;
    return _yt.currentQueue.indexWhere((item) {
      final qTitle = (item['title'] ?? '').toString().toLowerCase();
      return qTitle == dTitle || qTitle.contains(dTitle) || dTitle.contains(qTitle);
    });
  }

  /// Auto-start playback when a song is added while collab is enabled and nothing
  /// is currently playing.
  void _maybeAutoStart() {
    if (_enabled && _currentPlayingIndex == -1 && _yt.currentQueue.isNotEmpty) {
      playAt(0);
    }
  }

  // --- Enable / Disable ---
  void enable() {
    _enabled = true;
    _persist();
    notifyListeners();
    // Explicit action: play the saved song from its start.
    if (_yt.currentQueue.isNotEmpty) {
      playAt(_currentPlayingIndex < 0 || _currentPlayingIndex >= _yt.currentQueue.length
          ? 0
          : _currentPlayingIndex);
    }
  }

  void disable() {
    // "Keep playing": stop managing but do NOT pause. The index is retained so
    // re-enabling resumes from the same song.
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
    _persist();
    notifyListeners();

    final item = _yt.currentQueue[index];
    final videoId = item['videoId'];
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
        _playViaIntent(query);
      }
    }).catchError((e) {
      debugPrint("Collab: MediaSession error: $e, falling back to intent");
      _playViaIntent(query);
    });
  }

  void _playViaIntent(String query) {
    final intent = AndroidIntent(
      action: 'android.media.action.MEDIA_PLAY_FROM_SEARCH',
      arguments: <String, dynamic>{'query': query},
      package: 'com.google.android.apps.youtube.music',
    );
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
    await _yt.clearPlaylist();
    await _persist();
    notifyListeners();
  }

  // --- Session reset (the ONLY full reset path) ---
  Future<void> newSession() async {
    _sessionId = _generateSessionId();
    _currentPlayingIndex = -1;
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
