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

/// Which queue is currently driving/being displayed. [collab] is the app's own
/// built queue (favorites/collab, driven via [CollabService.playAt]). [native]
/// is a passive mirror of YT Music's own queue (V4.5 pivot) — the app issues at
/// most a one-shot trigger ([CollabService.playNativeMix]) and otherwise only
/// reads state; no reassert/inference, so no double-transition jank.
enum QueueSource { collab, native }

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
  static const String _queueSourceKey = 'collab_queue_source';

  final DashboardProvider _dashboard;
  final YouTubeService _yt;

  io.Socket? _socket;

  String _sessionId = '';
  bool _enabled = false; // "Collab enabled" = passenger sharing is open (NOT playback).
  int _currentPlayingIndex = -1;
  // True while we are actively driving the queue (so Auto-DJ advances at song end).
  // Decoupled from _enabled so favorites playback works with Collab off.
  bool _playbackActive = false;
  // Epoch ms of the last "external PREVIOUS at the start of the queue → restart
  // to start" no-op (see _onDashboardUpdate). Our queue track is the ROOT of YT
  // Music's own radio queue, so pressing PREVIOUS again there has nothing to go
  // back to in YT Music's underlying playlist — on some presses YT Music restarts
  // (handled above), but on others it instead wanders into its own autoplay/radio
  // and surfaces an unrelated track. That foreign track would normally read as an
  // external NEXT and advance our queue FORWARD — turning a second PREVIOUS press
  // into a forward skip. If a foreign track appears shortly after this no-op, we
  // treat it as fallout from that same PREVIOUS press and snap back to the CURRENT
  // item instead of advancing.
  int _restartedAtStartMs = 0;
  bool _allowEditing = false;
  bool _allowMediaControl = false;
  // Which queue is currently in control — see [QueueSource]. Switching to
  // native is non-destructive: the collab queue and _currentPlayingIndex are
  // preserved so switching back to collab picks up where it left off.
  QueueSource _queueSource = QueueSource.collab;

  // Tracked to detect changes coming from DashboardProvider notifications.
  String _lastTrack = '';
  bool _lastPlaying = false;
  // Previous poll's media position (ms). A sharp backward jump on the SAME track
  // is our signal for an external PREVIOUS press (see _onDashboardUpdate).
  double _lastPosMs = 0;
  // When we last issued a playAt (epoch ms). For a short window after, native
  // position readings are still settling from the previous track (old high value →
  // new ~0), which would masquerade as a backward jump — so PREVIOUS detection is
  // suppressed during it.
  int _lastPlayAtMs = 0;

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

  /// Which queue is currently in control (see [QueueSource]).
  QueueSource get queueSource => _queueSource;

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
      _queueSource = prefs.getString(_queueSourceKey) == 'native' ? QueueSource.native : QueueSource.collab;
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
    if (restoredIdx != -1 && _queueSource != QueueSource.native) {
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
      await prefs.setString(_queueSourceKey, _queueSource == QueueSource.native ? 'native' : 'collab');
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

    // Native mode: still mirror play state / track for the UI and passengers,
    // but don't reassert or auto-advance the collab queue — see
    // switchToNative()/switchToCollab(). The actual native queue display comes
    // from DashboardProvider.nativeQueue, not from anything tracked here.
    if (_queueSource == QueueSource.native) {
      if (_dashboard.isPlaying != _lastPlaying) {
        _lastPlaying = _dashboard.isPlaying;
        _socket?.emit('update_play_state', _lastPlaying);
      }
      if (_dashboard.currentTrack != _lastTrack) {
        _lastTrack = _dashboard.currentTrack;
        _socket?.emit('update_playing_status', _lastTrack);
      }
      return;
    }

    // Sync play/pause state to passengers whenever it changes.
    if (_dashboard.isPlaying != _lastPlaying) {
      _lastPlaying = _dashboard.isPlaying;
      _socket?.emit('update_play_state', _lastPlaying);
    }

    // Runs on every tick (incl. position-only updates) — must be before the
    // unchanged-track early-return below.
    _scheduleEndAdvance();

    // Detect an external PREVIOUS press (car / Bluetooth / notification) and turn it
    // into "go back one" in OUR queue. Because we play each queue item as the root of
    // YT Music's radio queue (index 0), a PREVIOUS press has nothing "before" it, so
    // YT Music just RESTARTS the current track: the title stays the same while the
    // position jumps back to ~0. Verified on-device (2026-07-09). That backward jump
    // on the still-current track — which we didn't command (guarded by _advancing) —
    // is our unambiguous PREVIOUS signal (NEXT, by contrast, produces a *foreign*
    // track; see below). This must run before the unchanged-track early-return since a
    // restart keeps the same title.
    final curPosMs = _dashboard.mediaPosition;
    final prevPosMs = _lastPosMs;
    _lastPosMs = curPosMs;
    final sincePlayMs = DateTime.now().millisecondsSinceEpoch - _lastPlayAtMs;
    // A sharp backward jump to ~start on the SAME track = YT Music restarting the
    // current song, i.e. an external PREVIOUS press (our track is the root of YT
    // Music's radio queue, so "previous" has nothing before it and just restarts).
    final backwardReset = curPosMs < 2500 && (prevPosMs - curPosMs) > 1200;
    if (_playbackActive &&
        !_advancing &&
        // Was 2500ms when this only ran off a 1s poll; now dashboard state is
        // pushed near-instantly by the native MediaController callback (see
        // DashboardProvider._startMediaEventListener), so the settling window
        // right after our own track change is shorter too. UNVERIFIED
        // on-device — tune back up if real rapid-skip tests still misfire.
        sincePlayMs > 1500 && // ignore position settling right after our own track change
        _currentPlayingIndex >= 0 &&
        _dashboard.currentTrack == _lastTrack && // same track (a restart, not a new song)
        backwardReset) {
      // Standard media semantics, decided by how far in they were when they pressed
      // (prevPosMs, the position just before the reset):
      if (prevPosMs > 4000 || _currentPlayingIndex == 0) {
        // >4s in (or nothing before it) → "previous" means restart-to-start. YT Music
        // already reset the track to 0, so just leave it there.
        _restartedAtStartMs = DateTime.now().millisecondsSinceEpoch;
        debugPrint("Collab: external PREVIOUS → restart current to start");
      } else {
        // Near the start → go to the previous queue item.
        _currentPlayingIndex--;
        debugPrint("Collab: external PREVIOUS → index $_currentPlayingIndex");
        playAt(_currentPlayingIndex);
      }
      return;
    }

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
      // A FOREIGN track appeared while we're driving the queue: either our track ended
      // (YT Music autoplayed its own next-up) or an external NEXT (car / Bluetooth /
      // notification) — both surface as "a non-queue track is now playing" and both
      // mean "move the queue forward". (An external PREVIOUS is caught earlier as a
      // same-track restart, so it does NOT reach here — EXCEPT when YT Music, having
      // nothing before our queue's root track, wanders into its own autoplay instead
      // of restarting; see _restartedAtStartMs.)
      final recentRestart = _restartedAtStartMs != 0 &&
          DateTime.now().millisecondsSinceEpoch - _restartedAtStartMs < 3000;
      _restartedAtStartMs = 0;
      if (recentRestart) {
        // Fallout from the PREVIOUS press we just handled as a restart — snap
        // back to the current item rather than reading this as a NEXT.
        debugPrint("Collab Auto-DJ: foreign track after a start-of-queue PREVIOUS → "
            "re-asserting current index $_currentPlayingIndex (not advancing)");
        playAt(_currentPlayingIndex);
        return;
      }
      // The queue is authoritative: advance to our next item so an external
      // NEXT / song-end never "loses" it. playAt() re-arms _advancing while YT
      // Music loads the target, so autoplay flashing non-matching tracks can't
      // skip entries.
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
    if (_queueSource != QueueSource.native && !_playbackActive && _currentPlayingIndex == -1 && _yt.currentQueue.isNotEmpty) {
      playAt(0);
    }
  }

  // --- Favorites playback entry points (replace the queue and play "now") ---

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

  /// Releases the collab queue's grip on playback without touching it: YT
  /// Music's own queue/autoplay (and picking a song directly on the car
  /// screen) is no longer fought by the reclaim logic in [_onDashboardUpdate].
  /// Non-destructive — the collab queue and [_currentPlayingIndex] are
  /// untouched, so [switchToCollab] (or tapping any queue row, via [playAt])
  /// picks back up where it left off.
  void switchToNative() {
    if (_queueSource == QueueSource.native) return;
    _queueSource = QueueSource.native;
    _enabled = false; // nothing collab-driven to share while mirroring YT Music
    _persist();
    notifyListeners();
  }

  /// Resumes driving the collab queue. If the currently-playing native track
  /// matches a queue entry, syncs the highlight/Auto-DJ to it immediately;
  /// otherwise the queue stays paused-in-place until the user taps a row
  /// (same as a cold restore).
  void switchToCollab() {
    if (_queueSource == QueueSource.collab) return;
    _queueSource = QueueSource.collab;
    final idx = _matchQueueIndex(_lastTrack);
    if (idx != -1) {
      _currentPlayingIndex = idx;
      _playbackActive = true;
    }
    _persist();
    notifyListeners();
  }

  /// Triggers a mix/radio/playlist/single-song to play NATIVELY in YT Music
  /// (V4.5 pivot) — the app issues this one command and then only mirrors
  /// whatever queue results (DashboardProvider.nativeQueue); it never builds
  /// its own track list or drives playback for this path, so there's no
  /// reassert/inference to race against YT Music's own skip handling.
  /// [listId] is a playlist/mix/radio id; [videoId] alone (no listId) plays a
  /// single track and lets YT Music build its own autoplay radio around it —
  /// at least one of the two is required.
  Future<void> playNativeMix({String? listId, String? videoId}) async {
    assert((listId != null && listId.isNotEmpty) || (videoId != null && videoId.isNotEmpty),
        'playNativeMix requires a listId or a videoId');
    _queueSource = QueueSource.native;
    _enabled = false; // nothing collab-driven to share while mirroring YT Music
    _dashboard.clearNativeQueueHistory(); // fresh mix — don't carry over the last one's played history
    _persist();
    notifyListeners();
    try {
      final result = await DashboardProvider.platform.invokeMethod('playNativeMix', {
        if (listId != null && listId.isNotEmpty) 'listId': listId,
        if (videoId != null && videoId.isNotEmpty) 'videoId': videoId,
      });
      debugPrint('Collab: playNativeMix result: $result');
      final success = result is Map && result['success'] == true;
      if (!success) {
        // No YT Music session yet (cold start / app not launched this run) —
        // same fallback playAt() uses: launch YT Music directly on the mix's
        // watch URL, which also warms up its session for next time.
        debugPrint('Collab: playNativeMix failed, falling back to intent');
        _playViaIntent('', videoId: videoId, listId: listId);
      }
    } catch (e) {
      debugPrint('Collab: playNativeMix error: $e');
      _playViaIntent('', videoId: videoId, listId: listId);
    }
  }

  // --- Native transport passthrough (QueueSource.native) — no local state to
  // reconcile afterward; the push event reports whatever actually happens.
  Future<void> nativeNext() async {
    try {
      await DashboardProvider.platform.invokeMethod('nativeSkipNext');
    } catch (e) {
      debugPrint('Collab: nativeSkipNext error: $e');
    }
  }

  Future<void> nativePrevious() async {
    try {
      await DashboardProvider.platform.invokeMethod('nativeSkipPrevious');
    } catch (e) {
      debugPrint('Collab: nativeSkipPrevious error: $e');
    }
  }

  Future<void> nativeTogglePlayPause() async {
    try {
      await DashboardProvider.platform.invokeMethod('nativeTogglePlayPause');
    } catch (e) {
      debugPrint('Collab: nativeTogglePlayPause error: $e');
    }
  }

  Future<void> nativeSkipToQueueItem(int queueId) async {
    try {
      await DashboardProvider.platform.invokeMethod('nativeSkipToQueueItem', {'queueId': queueId});
    } catch (e) {
      debugPrint('Collab: nativeSkipToQueueItem error: $e');
    }
  }

  // --- Media controls ---
  void next() {
    if (_queueSource == QueueSource.native) {
      nativeNext();
      return;
    }
    if (_currentPlayingIndex != -1 && _yt.currentQueue.length > _currentPlayingIndex + 1) {
      playAt(_currentPlayingIndex + 1);
    } else {
      FlutterMediaController.nextTrack();
    }
  }

  void previous() {
    if (_queueSource == QueueSource.native) {
      nativePrevious();
      return;
    }
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
    _queueSource = QueueSource.collab; // any deliberate collab play means "drive the queue again"
    _currentPlayingIndex = index;
    _playbackActive = true;
    _lastPlayAtMs = DateTime.now().millisecondsSinceEpoch; // suppress PREVIOUS mis-detect while position settles
    // Guard Auto-DJ from advancing off this track until YT Music actually loads
    // it. Right after a deliberate play the native metadata still reports the
    // PREVIOUS song (which isn't in the new queue), and without this the Auto-DJ
    // would instantly skip to index+1. Cleared when `_matchQueueIndex` sees the
    // target load; self-heals after 10s if it never does.
    _advancing = true;
    // Was 10s to cover the worst case of a 1s poll missing the target load;
    // with push events the real match (_matchQueueIndex, above) should clear
    // _advancing within ~1-2s, so this is just the self-heal fallback if it
    // never does. UNVERIFIED on-device — tune back up if this ever clears
    // before YT Music actually finishes loading the target.
    Future.delayed(const Duration(seconds: 5), () => _advancing = false);
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

  void _playViaIntent(String query, {String? videoId, String? listId}) {
    // Prefer the EXACT track by its watch URL. A search intent (the old fallback)
    // resolves to whatever YT Music ranks first — often the wrong song or a video
    // version — which is why a cold-start album could open on the wrong track.
    final AndroidIntent intent;
    if (listId != null && listId.isNotEmpty) {
      final data = videoId != null && videoId.isNotEmpty
          ? 'https://music.youtube.com/watch?v=$videoId&list=$listId'
          : 'https://music.youtube.com/watch?list=$listId';
      intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: data,
        package: 'com.google.android.apps.youtube.music',
      );
    } else if (videoId != null && videoId.isNotEmpty) {
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
    _queueSource = QueueSource.collab;
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
    _queueSource = QueueSource.collab;
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
