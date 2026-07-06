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
  // Caches full YT Music song metadata ({videoId, title, artist, thumbnail}) keyed by search query.
  final Map<String, Map<String, String>> _ytMusicSongCache = {};

  bool _isAdding = false;

  String? lastAddedVideoId;
  DateTime? lastAddedTime;

  /// Strips common YouTube title noise so the query fed to YT Music is clean.
  String _cleanTitle(String title) => title
      .replaceAll(RegExp(r'\(.*?\)'), '')
      .replaceAll(RegExp(r'\[.*?\]'), '')
      .replaceAll(RegExp(r'official audio', caseSensitive: false), '')
      .replaceAll(RegExp(r'official video', caseSensitive: false), '')
      .replaceAll(RegExp(r'music video', caseSensitive: false), '')
      .replaceAll(RegExp(r'lyric[s]? video', caseSensitive: false), '')
      .trim();

  String _cleanChannel(String channel) => channel
      .replaceAll(RegExp(r' - Topic', caseSensitive: false), '')
      .replaceAll(RegExp(r'VEVO', caseSensitive: false), '')
      .trim();

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

  /// Searches YT Music directly (Innertube API, "Songs" filter) and returns the
  /// top song's full metadata: {videoId, title, artist, thumbnail}.
  ///
  /// This is the single source of truth for the queue. YT Music's own search
  /// resolves the correct audio-only "song" version (from "Artist - Topic"
  /// channels), so we no longer chain YouTube Data API + iTunes lookups (each of
  /// which trusted the previous hop's top result and compounded mismatches).
  Future<Map<String, String>?> _searchYTMusicSong(String query) async {
    final cacheKey = query.trim().toLowerCase();
    if (cacheKey.isEmpty) return null;
    if (_ytMusicSongCache.containsKey(cacheKey)) {
      return _ytMusicSongCache[cacheKey];
    }

    try {
      final url = Uri.parse('https://music.youtube.com/youtubei/v1/search?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20231204.01.00',
            },
          },
          'query': query,
          'params': 'EgWKAQIIAWoKEAkQBRAKEAMQBA==', // Filter: Songs only
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Navigate the nested Innertube response to the first song shelf item.
        final tabs = data['contents']?['tabbedSearchResultsRenderer']?['tabs'];
        if (tabs is List && tabs.isNotEmpty) {
          final sectionList = tabs[0]['tabRenderer']?['content']?['sectionListRenderer']?['contents'];
          if (sectionList is List) {
            for (final section in sectionList) {
              final shelfContents = section['musicShelfRenderer']?['contents'];
              if (shelfContents is List && shelfContents.isNotEmpty) {
                for (final item in shelfContents) {
                  final renderer = item['musicResponsiveListItemRenderer'];
                  if (renderer == null) continue;
                  final song = _parseSongRenderer(renderer);
                  if (song != null) {
                    debugPrint('YT Music resolved "$query" → "${song['title']}" by "${song['artist']}" (${song['videoId']})');
                    _ytMusicSongCache[cacheKey] = song;
                    return song;
                  }
                }
              }
            }
          }
        }
      }
      debugPrint('YT Music search returned no song results for "$query"');
    } catch (e) {
      debugPrint('YT Music search failed: $e');
    }
    return null;
  }

  /// Extracts {videoId, title, artist, thumbnail} from a musicResponsiveListItemRenderer.
  /// Returns null if no playable video ID can be found.
  Map<String, String>? _parseSongRenderer(Map renderer) {
    // Video ID: prefer playlistItemData, fall back to the overlay play button.
    String? videoId = renderer['playlistItemData']?['videoId']?.toString();
    if (videoId == null || videoId.isEmpty) {
      videoId = renderer['overlay']?['musicItemThumbnailOverlayRenderer']
          ?['content']?['musicPlayButtonRenderer']
          ?['playNavigationEndpoint']?['watchEndpoint']?['videoId']?.toString();
    }
    if (videoId == null || videoId.isEmpty) return null;

    String title = '';
    String artist = '';
    final flexColumns = renderer['flexColumns'];
    if (flexColumns is List && flexColumns.isNotEmpty) {
      // Column 0 = title.
      final titleRuns = flexColumns[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
      if (titleRuns is List && titleRuns.isNotEmpty) {
        title = titleRuns[0]?['text']?.toString() ?? '';
      }
      // Column 1 = "Artist • Album • Duration"; first run is the primary artist.
      if (flexColumns.length > 1) {
        final subRuns = flexColumns[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
        if (subRuns is List && subRuns.isNotEmpty) {
          artist = subRuns[0]?['text']?.toString() ?? '';
        }
      }
    }

    String thumbnail = '';
    final thumbs = renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];
    if (thumbs is List && thumbs.isNotEmpty) {
      thumbnail = thumbs.last['url']?.toString() ?? '';
      // Bump the sizing params (e.g. =w60-h60) up for a crisp queue thumbnail.
      thumbnail = thumbnail.replaceAll(RegExp(r'=w\d+-h\d+'), '=w400-h400');
    }

    return {
      'videoId': videoId,
      'title': title.isNotEmpty ? title : 'Unknown',
      'artist': artist,
      'thumbnail': thumbnail,
    };
  }

  /// Fetches the real title of a YouTube video via the Data API. Used when an
  /// add request arrives with only a videoId (e.g. shared links), so we have a
  /// meaningful query to hand to YT Music search.
  Future<String?> _fetchYouTubeVideoTitle(String videoId) async {
    if (_youtubeApi == null) return null;
    try {
      return await _withAuthRetry<String?>(() async {
        final res = await _youtubeApi!.videos.list(['snippet'], id: [videoId]);
        final items = res.items;
        if (items != null && items.isNotEmpty) {
          final snippet = items.first.snippet;
          return '${snippet?.title ?? ''} ${snippet?.channelTitle ?? ''}'.trim();
        }
        return null;
      });
    } catch (e) {
      debugPrint('Failed to fetch YouTube video title for $videoId: $e');
      return null;
    }
  }

  /// Adds a song given a YouTube videoId (e.g. from a shared link / passenger
  /// "add by id"). We build a text query from the provided title/channel (or
  /// look up the real YouTube title if none was supplied) and route it through
  /// YT Music search so the queue gets the correct audio-only song version.
  Future<bool> addVideoToPlaylist(String videoId, {String title = '', String channel = '', String thumbnail = ''}) async {
    // Build the best query we can for YT Music.
    String query = _cleanTitle(title);
    final cleanChannel = _cleanChannel(channel);
    if (cleanChannel.isNotEmpty) query = '$query $cleanChannel'.trim();

    // No usable metadata came with the request — fetch the real video title.
    if (query.isEmpty) {
      final fetched = await _fetchYouTubeVideoTitle(videoId);
      if (fetched != null) query = _cleanTitle(fetched);
    }

    if (query.isNotEmpty) {
      final song = await _searchYTMusicSong(query);
      if (song != null && song['videoId']!.isNotEmpty) {
        debugPrint('Queue: Using YT Music song ID (${song['videoId']}) for "${song['title']}" (from videoId $videoId)');
        return _addResolvedSong(song, originalVideoId: videoId);
      }
    }

    // Fallback: queue the original video with whatever metadata we have.
    debugPrint('Queue: Falling back to original video ID ($videoId); YT Music resolution failed for "$query"');
    return _addResolvedSong({
      'videoId': videoId,
      'title': _cleanTitle(title).isNotEmpty ? _cleanTitle(title) : (query.isNotEmpty ? query : 'Unknown'),
      'artist': cleanChannel,
      'thumbnail': thumbnail,
    }, originalVideoId: videoId);
  }

  /// Inserts a fully-resolved song ({videoId, title, artist, thumbnail}) into the
  /// local queue, applying dedup and the 5-second repeat guard.
  Future<bool> _addResolvedSong(Map<String, String> song, {required String originalVideoId}) async {
    while (_isAdding) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _isAdding = true;
    try {
      final videoId = song['videoId'] ?? originalVideoId;

      if (lastAddedVideoId == videoId && lastAddedTime != null && DateTime.now().difference(lastAddedTime!).inSeconds < 5) {
        debugPrint("Ignoring duplicate add request for same video within 5 seconds.");
        return true;
      }

      final existingIndex = currentQueue.indexWhere((item) => item['videoId'] == videoId);
      if (existingIndex != -1) {
        currentQueue.removeAt(existingIndex);
      }

      currentQueue.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(), // Unique local ID
        'videoId': videoId,
        'originalVideoId': originalVideoId,
        'title': song['title'] ?? 'Unknown',
        'artist': song['artist'] ?? '',
        'thumbnail': song['thumbnail'] ?? '',
      });

      lastAddedTime = DateTime.now();
      lastAddedVideoId = videoId;

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint("Error adding song to local queue: $e");
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

  Future<void> reorderSong(String playlistItemId, int newPosition) async {
    final index = currentQueue.indexWhere((item) => item['id'] == playlistItemId);
    if (index != -1) {
      final item = currentQueue.removeAt(index);
      currentQueue.insert(newPosition.clamp(0, currentQueue.length), item);
      notifyListeners();
    }
  }

  /// Passenger typed a free-text query. Search YT Music directly with the "Songs"
  /// filter and queue the top result — no YouTube Data API / iTunes middlemen.
  Future<bool> searchAndAddSong(String query) async {
    try {
      final song = await _searchYTMusicSong(query);
      if (song != null && song['videoId']!.isNotEmpty) {
        return await _addResolvedSong(song, originalVideoId: song['videoId']!);
      }
      debugPrint('searchAndAddSong: no YT Music result for "$query"');
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
