import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:http/http.dart' as http;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

class YouTubeService extends ChangeNotifier {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      youtube.YouTubeApi.youtubeScope,
    ],
  );

  GoogleSignInAccount? _currentUser;
  youtube.YouTubeApi? _youtubeApi;
  String? _playlistId;

  GoogleSignInAccount? get currentUser => _currentUser;
  bool get isSignedIn => _currentUser != null;
  String? get playlistId => _playlistId;
  
  List<Map<String, dynamic>> currentQueue = [];

  YouTubeService() {
    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) async {
      _currentUser = account;
      if (_currentUser != null) {
        // Authenticate YouTube API
        final authClient = await _googleSignIn.authenticatedClient();
        if (authClient != null) {
          _youtubeApi = youtube.YouTubeApi(authClient);
          await _ensurePlaylistExists();
          await fetchQueue();
        }
      }
      notifyListeners();
    });
    _googleSignIn.signInSilently();
  }

  Future<void> signIn() async {
    try {
      await _googleSignIn.signIn();
    } catch (error) {
      debugPrint("Google Sign In Error: $error");
      rethrow;
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.disconnect();
    _youtubeApi = null;
    _playlistId = null;
    notifyListeners();
  }

  Future<void> _ensurePlaylistExists() async {
    if (_youtubeApi == null) return;
    try {
      // Check if "Carpanion Queue" exists
      final playlists = await _youtubeApi!.playlists.list(
        ['snippet', 'id'],
        mine: true,
        maxResults: 50,
      );

      final existing = playlists.items?.firstWhere(
        (p) => p.snippet?.title == 'Carpanion Queue',
        orElse: () => youtube.Playlist(),
      );

      if (existing != null && existing.id != null) {
        _playlistId = existing.id;
      } else {
        // Create new playlist
        final newPlaylist = youtube.Playlist()
          ..snippet = (youtube.PlaylistSnippet()
            ..title = 'Carpanion Queue'
            ..description = 'Queue created by Carpanion PWA passengers')
          ..status = (youtube.PlaylistStatus()..privacyStatus = 'unlisted');

        final created = await _youtubeApi!.playlists.insert(newPlaylist, ['snippet', 'status']);
        _playlistId = created.id;
      }
      notifyListeners();
    } catch (e) {
      debugPrint("Error ensuring playlist: $e");
    }
  }

  Future<bool> addVideoToPlaylist(String videoId) async {
    if (_youtubeApi == null || _playlistId == null) return false;
    try {
      final item = youtube.PlaylistItem()
        ..snippet = (youtube.PlaylistItemSnippet()
          ..playlistId = _playlistId
          ..resourceId = (youtube.ResourceId()
            ..kind = 'youtube#video'
            ..videoId = videoId));
            
      await _youtubeApi!.playlistItems.insert(item, ['snippet']);
      await fetchQueue();
      return true;
    } catch (e) {
      debugPrint("Error adding video to playlist: $e");
      return false;
    }
  }

  Future<void> fetchQueue() async {
    if (_youtubeApi == null || _playlistId == null) return;
    try {
      final items = await _youtubeApi!.playlistItems.list(
        ['snippet', 'contentDetails'], 
        playlistId: _playlistId, 
        maxResults: 50
      );
      
      currentQueue = items.items?.map((item) {
        return {
          'id': item.id ?? '',
          'videoId': item.snippet?.resourceId?.videoId ?? '',
          'title': item.snippet?.title ?? 'Unknown',
          'thumbnail': item.snippet?.thumbnails?.default_?.url ?? '',
          'position': item.snippet?.position ?? 0,
        };
      }).toList() ?? [];
      
      currentQueue.sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
      notifyListeners();
    } catch (e) {
      debugPrint("Error fetching queue: $e");
    }
  }

  Future<void> deleteSong(String playlistItemId) async {
    if (_youtubeApi == null) return;
    try {
      await _youtubeApi!.playlistItems.delete(playlistItemId);
      await fetchQueue();
    } catch (e) {
      debugPrint("Error deleting song: $e");
    }
  }

  Future<void> reorderSong(String playlistItemId, String videoId, int newPosition) async {
    if (_youtubeApi == null || _playlistId == null) return;
    try {
      final item = youtube.PlaylistItem()
        ..id = playlistItemId
        ..snippet = (youtube.PlaylistItemSnippet()
          ..playlistId = _playlistId
          ..resourceId = (youtube.ResourceId()..kind = 'youtube#video'..videoId = videoId)
          ..position = newPosition);
      await _youtubeApi!.playlistItems.update(item, ['snippet']);
      await fetchQueue();
    } catch (e) {
      debugPrint("Error reordering song: $e");
    }
  }

  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    if (_youtubeApi == null) return [];
    try {
      final res = await _youtubeApi!.search.list(
        ['snippet'], 
        q: query, 
        type: ['video'], 
        videoCategoryId: '10',
        maxResults: 10
      );
      return res.items?.map((item) {
        return {
          'videoId': item.id?.videoId ?? '',
          'title': item.snippet?.title ?? 'Unknown',
          'thumbnail': item.snippet?.thumbnails?.default_?.url ?? '',
          'channel': item.snippet?.channelTitle ?? '',
        };
      }).toList() ?? [];
    } catch (e) {
      debugPrint("Error searching songs: $e");
      return [];
    }
  }
}
