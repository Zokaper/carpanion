import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:http/http.dart' as http;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

class YouTubeService extends ChangeNotifier {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [youtube.YouTubeApi.youtubeScope],
  );

  GoogleSignInAccount? _currentUser;
  youtube.YouTubeApi? _youtubeApi;

  GoogleSignInAccount? get currentUser => _currentUser;
  bool get isSignedIn => _currentUser != null;
  
  List<Map<String, dynamic>> currentQueue = [];
  final Map<String, Map<String, String>> _itunesMetadataCache = {};

  bool _isAdding = false;

  String? lastAddedVideoId;
  DateTime? lastAddedTime;

  Future<Map<String, String>> _getItunesMetadata(String youtubeTitle, String youtubeChannel, String defaultThumb) async {
    final cacheKey = '$youtubeTitle|$youtubeChannel';
    if (_itunesMetadataCache.containsKey(cacheKey)) {
      return _itunesMetadataCache[cacheKey]!;
    }
    
    String cleanTitle = youtubeTitle
      .replaceAll(RegExp(r'\(.*?\)'), '')
      .replaceAll(RegExp(r'\[.*?\]'), '')
      .replaceAll(RegExp(r'official audio', caseSensitive: false), '')
      .replaceAll(RegExp(r'music video', caseSensitive: false), '')
      .trim();
      
    String cleanChannel = youtubeChannel
      .replaceAll(RegExp(r' - Topic', caseSensitive: false), '')
      .replaceAll(RegExp(r'VEVO', caseSensitive: false), '')
      .trim();
      
    try {
      final searchTerm = Uri.encodeComponent('$cleanTitle $cleanChannel');
      final url = Uri.parse('https://itunes.apple.com/search?term=$searchTerm&entity=song&limit=1');
      var res = await http.get(url).timeout(const Duration(seconds: 3));
      var data = jsonDecode(res.body);

      if (data['results'] != null && data['results'].isNotEmpty) {
        final trackName = data['results'][0]['trackName']?.toString() ?? cleanTitle;
        final artistName = data['results'][0]['artistName']?.toString() ?? 'Unknown Artist';
        final artwork = data['results'][0]['artworkUrl100']?.toString() ?? defaultThumb;
        // Replace with higher resolution artwork (100x100 to 400x400)
        final highResArtwork = artwork.replaceAll('100x100bb.jpg', '400x400bb.jpg');
        final meta = {'title': trackName, 'artist': artistName, 'thumbnail': highResArtwork};
        _itunesMetadataCache[cacheKey] = meta;
        return meta;
      }
    } catch(e) {
      debugPrint("iTunes metadata fetch failed for $youtubeTitle: $e");
    }
    
    final meta = {'title': cleanTitle, 'artist': cleanChannel.isNotEmpty ? cleanChannel : 'YouTube', 'thumbnail': defaultThumb};
    // Do not cache the fallback so it can retry next time
    return meta;
  }

  YouTubeService() {
    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) async {
      _currentUser = account;
      if (_currentUser != null) {
        final authClient = await _googleSignIn.authenticatedClient();
        if (authClient != null) {
          _youtubeApi = youtube.YouTubeApi(authClient);
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
    notifyListeners();
  }

  Future<T?> _withAuthRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('invalid_token') || errorStr.contains('Access was denied') || errorStr.contains('401')) {
        debugPrint("Token expired, attempting to refresh...");
        try {
          await _googleSignIn.signInSilently();
          final authClient = await _googleSignIn.authenticatedClient();
          if (authClient != null) {
            _youtubeApi = youtube.YouTubeApi(authClient);
            return await action();
          }
        } catch (refreshErr) {
          debugPrint("Refresh failed: $refreshErr");
        }
      }
      rethrow;
    }
  }

  Future<bool> addVideoToPlaylist(String videoId, {String title = 'Unknown', String channel = 'YouTube', String thumbnail = ''}) async {
    while (_isAdding) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    _isAdding = true;
    try {
      if (lastAddedVideoId == videoId && lastAddedTime != null && DateTime.now().difference(lastAddedTime!).inSeconds < 5) {
        debugPrint("Ignoring duplicate add request for same video within 5 seconds.");
        return true;
      }

      final existingIndex = currentQueue.indexWhere((item) => item['videoId'] == videoId);
      if (existingIndex != -1) {
        currentQueue.removeAt(existingIndex);
      }

      final meta = await _getItunesMetadata(title, channel, thumbnail);

      final newItem = {
        'id': DateTime.now().millisecondsSinceEpoch.toString(), // Unique local ID
        'videoId': videoId,
        'title': meta['title'],
        'artist': meta['artist'],
        'thumbnail': meta['thumbnail'],
      };

      currentQueue.add(newItem);

      lastAddedTime = DateTime.now();
      lastAddedVideoId = videoId;
      
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint("Error adding video to local queue: $e");
      return false;
    } finally {
      _isAdding = false;
    }
  }

  Future<void> clearPlaylist() async {
    currentQueue.clear();
    notifyListeners();
  }

  Future<void> fetchQueue() async {
    // No longer an API fetch, just notify listeners of local state.
    notifyListeners();
  }

  Future<void> deleteSong(String playlistItemId) async {
    currentQueue.removeWhere((item) => item['id'] == playlistItemId);
    notifyListeners();
  }

  Future<void> reorderSong(String playlistItemId, String videoId, int newPosition) async {
    final index = currentQueue.indexWhere((item) => item['id'] == playlistItemId);
    if (index != -1) {
      final item = currentQueue.removeAt(index);
      currentQueue.insert(newPosition.clamp(0, currentQueue.length), item);
      notifyListeners();
    }
  }

  Future<bool> searchAndAddSong(String query) async {
    try {
      final res = await searchSongs('$query official audio');
      if (res.isNotEmpty) {
        final item = res.first;
        return await addVideoToPlaylist(
          item['videoId'], 
          title: item['title'], 
          channel: item['channel'], 
          thumbnail: item['thumbnail']
        );
      }
      return false;
    } catch (e) {
      debugPrint("Error in searchAndAddSong: $e");
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> searchSongs(String query) async {
    if (_youtubeApi == null) return [];
    try {
      return await _withAuthRetry(() async {
        final res = await _youtubeApi!.search.list(
          ['snippet'], 
          q: query, 
          type: ['video'], 
          maxResults: 10
        );
        return res.items?.map((item) {
          return {
            'videoId': item.id?.videoId ?? '',
            'title': item.snippet?.title ?? 'Unknown',
            'thumbnail': item.snippet?.thumbnails?.default_?.url ?? '',
            'channel': item.snippet?.channelTitle ?? '',
          };
        }).toList() ?? <Map<String, dynamic>>[];
      }) ?? <Map<String, dynamic>>[];
    } catch (e) {
      debugPrint("Error searching songs: $e");
      return <Map<String, dynamic>>[];
    }
  }
}
