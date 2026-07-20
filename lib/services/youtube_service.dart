import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/youtube/v3.dart' as youtube;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

/// A tile on the favorites-screen mix grid (a personalized playlist/mix, or a
/// pre-fetched song list like "Quick picks").
class HomeTile {
  final String title;
  final String thumbnail;
  final String? playlistId;
  final List<Map<String, String>>? songs;
  const HomeTile({required this.title, required this.thumbnail, this.playlistId, this.songs});
}

class YouTubeService extends ChangeNotifier {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [youtube.YouTubeApi.youtubeScope],
  );

  GoogleSignInAccount? _currentUser;
  youtube.YouTubeApi? _youtubeApi;
  final math.Random _rng = math.Random();

  GoogleSignInAccount? get currentUser => _currentUser;
  bool get isSignedIn => _currentUser != null;

  // --- YouTube Music authenticated session (cookie/SAPISIDHASH, à la SimpMusic) ---
  // Captured from an in-app music.youtube.com login. Grants the personalized home
  // feed (Supermix, Quick Picks, …). Live account credentials → Keystore storage.
  static const _secureStore = FlutterSecureStorage();
  static const String _kYtmCookie = 'ytm_cookie';
  static const String _kYtmSapisid = 'ytm_sapisid';
  String? _ytmCookie;
  String? _ytmSapisid;
  bool get isYtmLoggedIn => _ytmCookie != null && _ytmSapisid != null;

  Future<void> loadYtmAuth() async {
    try {
      _ytmCookie = await _secureStore.read(key: _kYtmCookie);
      _ytmSapisid = await _secureStore.read(key: _kYtmSapisid);
    } catch (e) {
      debugPrint('loadYtmAuth failed: $e');
    }
    notifyListeners();
  }

  Future<void> setYtmAuth(String cookie, String sapisid) async {
    _ytmCookie = cookie;
    _ytmSapisid = sapisid;
    try {
      await _secureStore.write(key: _kYtmCookie, value: cookie);
      await _secureStore.write(key: _kYtmSapisid, value: sapisid);
    } catch (e) {
      debugPrint('setYtmAuth persist failed: $e');
    }
    notifyListeners();
  }

  Future<void> clearYtmAuth() async {
    _ytmCookie = null;
    _ytmSapisid = null;
    homeTiles = [];
    try {
      await _secureStore.delete(key: _kYtmCookie);
      await _secureStore.delete(key: _kYtmSapisid);
    } catch (e) {
      debugPrint('clearYtmAuth failed: $e');
    }
    notifyListeners();
  }

  /// The `SAPISIDHASH` Authorization value YT Music's web client uses:
  /// `SAPISIDHASH <ts>_<sha1(ts + " " + SAPISID + " " + origin)>`.
  String _sapisidHash() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final digest = crypto.sha1.convert(
      utf8.encode('$ts $_ytmSapisid https://music.youtube.com'),
    );
    return 'SAPISIDHASH ${ts}_$digest';
  }

  /// TEMP (Phase 1 validation): fetch the authenticated home feed and log its
  /// shelves so we can confirm cookie auth works and see the real JSON shape.
  Future<void> debugDumpHome() async {
    final data = await _innertubePost('browse', {'browseId': 'FEmusic_home'});
    if (data == null) {
      debugPrint('debugDumpHome: null (auth failed or no response)');
      return;
    }
    final shelves = <Map>[];
    _collectByKey(data, 'musicCarouselShelfRenderer', shelves);
    debugPrint('debugDumpHome: ${shelves.length} carousel shelves');
    for (final s in shelves) {
      final title = _runsText(s['header']?['musicCarouselShelfBasicHeaderRenderer']?['title']);
      final cards = <Map>[];
      _collectByKey(s, 'musicTwoRowItemRenderer', cards);
      final songs = <Map>[];
      _collectByKey(s, 'musicResponsiveListItemRenderer', songs);
      debugPrint('  shelf "$title": ${cards.length} cards, ${songs.length} song-rows');
      for (final c in cards.take(4)) {
        final ct = _rendererTitle(c);
        final pid = c['navigationEndpoint']?['watchPlaylistEndpoint']?['playlistId'] ??
            c['navigationEndpoint']?['browseEndpoint']?['browseId'];
        debugPrint('      card "$ct" id=$pid');
      }
    }
  }

  List<Map<String, dynamic>> currentQueue = [];
  // Personalized home-feed mix tiles (populated when logged into YT Music).
  List<HomeTile> homeTiles = [];
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

  static const String _queuePrefsKey = 'collab_queue';

  // Completes once the persisted queue has been restored (or failed to). Lets
  // CollabService wait for the queue before reconciling the now-playing highlight
  // on startup, instead of racing an empty queue.
  final Completer<void> _queueReady = Completer<void>();
  Future<void> get queueReady => _queueReady.future;

  YouTubeService() {
    _loadQueue();
    loadYtmAuth();
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

  /// Restores the persisted queue so it survives app restarts (e.g. Android Auto
  /// disconnecting and closing the app mid-drive).
  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queuePrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          currentQueue = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Failed to load persisted queue: $e');
    } finally {
      if (!_queueReady.isCompleted) _queueReady.complete();
    }
  }

  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queuePrefsKey, jsonEncode(currentQueue));
    } catch (e) {
      debugPrint('Failed to persist queue: $e');
    }
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
    final results = await searchYTMusicSongs(query, limit: 1);
    if (results.isEmpty) return null;
    debugPrint('YT Music resolved "$query" → "${results.first['title']}" by "${results.first['artist']}" (${results.first['videoId']})');
    _ytMusicSongCache[cacheKey] = results.first;
    return results.first;
  }

  /// Searches YT Music (Innertube "Songs" filter) and returns up to [limit]
  /// parsed song candidates ({videoId, title, artist, thumbnail}), best-first.
  /// Powers both single-song resolution and the PWA's search-results list —
  /// YT Music's own ranking is far better than iTunes for title+artist queries.
  Future<List<Map<String, String>>> searchYTMusicSongs(String query, {int limit = 8}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

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
          'query': trimmed,
          'params': 'EgWKAQIIAWoKEAkQBRAKEAMQBA==', // Filter: Songs only
        }),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = <Map<String, String>>[];
        // Navigate the nested Innertube response and collect song shelf items.
        final tabs = data['contents']?['tabbedSearchResultsRenderer']?['tabs'];
        if (tabs is List && tabs.isNotEmpty) {
          final sectionList = tabs[0]['tabRenderer']?['content']?['sectionListRenderer']?['contents'];
          if (sectionList is List) {
            for (final section in sectionList) {
              final shelfContents = section['musicShelfRenderer']?['contents'];
              if (shelfContents is List) {
                for (final item in shelfContents) {
                  final renderer = item['musicResponsiveListItemRenderer'];
                  if (renderer == null) continue;
                  final song = _parseSongRenderer(renderer);
                  if (song != null) {
                    results.add(song);
                    if (results.length >= limit) return results;
                  }
                }
              }
            }
          }
        }
        return results;
      }
      debugPrint('YT Music search returned no song results for "$trimmed"');
    } catch (e) {
      debugPrint('YT Music search failed: $e');
    }
    return [];
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

    // musicVideoType: ATV = audio track; OMV/UGC = a music/user video. Album
    // pages hand out OMV ids for tracks that have videos, which would play the
    // video version — callers use this to prefer the audio (ATV) id.
    final videoType = renderer['overlay']?['musicItemThumbnailOverlayRenderer']
        ?['content']?['musicPlayButtonRenderer']
        ?['playNavigationEndpoint']?['watchEndpoint']
        ?['watchEndpointMusicSupportedConfigs']?['watchEndpointMusicConfig']
        ?['musicVideoType']?.toString() ?? '';

    return {
      'videoId': videoId,
      'title': title.isNotEmpty ? title : 'Unknown',
      'artist': artist,
      'thumbnail': thumbnail,
      'videoType': videoType,
    };
  }

  // --- YT Music Innertube: albums & artist radio ------------------------------
  //
  // These power native favorites playback (album track lists / artist shuffle).
  // They are best-effort against YT Music's private Innertube API; every method
  // returns [] on any failure so callers fall back to the legacy YT Music launch.

  static const String _innertubeKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';

  Future<dynamic> _innertubePost(String endpoint, Map<String, dynamic> extraBody) async {
    final url = Uri.parse('https://music.youtube.com/youtubei/v1/$endpoint?key=$_innertubeKey&prettyPrint=false');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    };
    // When logged into YT Music, sign the request as the user so personalized
    // endpoints (the home feed) work. Anonymous callers are unaffected.
    if (isYtmLoggedIn) {
      headers['Cookie'] = _ytmCookie!;
      headers['Authorization'] = _sapisidHash();
      headers['X-Goog-AuthUser'] = '0';
    }
    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode({
        'context': {
          'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20231204.01.00'},
        },
        ...extraBody,
      }),
    ).timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) return jsonDecode(response.body);
    // Expired/invalid cookies → drop the session so the UI reverts to logged-out.
    if ((response.statusCode == 401 || response.statusCode == 403) && isYtmLoggedIn) {
      debugPrint('Innertube $endpoint ${response.statusCode} while authed — clearing YT Music session');
      clearYtmAuth();
    }
    debugPrint('Innertube $endpoint returned ${response.statusCode}');
    return null;
  }

  /// Fetches the ordered track list for an album by name+artist.
  Future<List<Map<String, String>>> getAlbumTracks(String album, String artist) async {
    try {
      final data = await _innertubePost('search', {'query': '$album $artist'.trim()});
      // Pick the album whose title best matches, preferring the STANDARD edition
      // over Deluxe/Expanded/Video (which carries the wrong cover + video ids).
      final albumId = _pickAlbumId(data, album, artist) ?? _findBrowseId(data, 'MPRE');
      if (albumId == null) {
        debugPrint('getAlbumTracks: no album browseId for "$album $artist"');
        return [];
      }
      final browse = await _innertubePost('browse', {'browseId': albumId});
      // Cover: the album HEADER thumbnail specifically, not a greedy first match
      // (which could grab a carousel/related-album image higher in the tree).
      final albumThumb = _findHeaderThumbnail(browse) ?? _findFirstThumbnail(browse);
      // Scope track collection to the album's track shelf so stray rows from
      // "related albums" shelves don't leak in.
      final shelf = _findFirstOfKey(browse, const ['musicPlaylistShelfRenderer', 'musicShelfRenderer']);
      final renderers = <Map>[];
      _collectByKey(shelf ?? browse, 'musicResponsiveListItemRenderer', renderers);
      final tracks = <Map<String, String>>[];
      for (final r in renderers) {
        final parsed = _parseSongRenderer(r);
        if (parsed == null) continue;
        // Album rows often omit per-row artist/thumbnail — fill from album context.
        if ((parsed['artist'] ?? '').isEmpty) parsed['artist'] = artist;
        if ((parsed['thumbnail'] ?? '').isEmpty && albumThumb != null) parsed['thumbnail'] = albumThumb;
        tracks.add(parsed);
      }
      // NOTE: album rows expose the VIDEO (OMV) id for tracks that have a music
      // video, so those play the video version. The reliable fix (re-resolving
      // each to its audio ATV id via a per-track search) is deferred — doing it
      // inline blocks playback, and a background swap needs the queue to carry
      // `videoType`. See `videoType` in _parseSongRenderer.
      debugPrint('getAlbumTracks: "$album" → ${tracks.length} tracks (album $albumId)');
      return tracks;
    } catch (e) {
      debugPrint('getAlbumTracks failed: $e');
      return [];
    }
  }

  /// Chooses the best-matching album browseId from a search response. Collects
  /// (title, MPRE id) candidates and scores by title match, penalizing
  /// Deluxe/Expanded/Video editions unless the requested album asked for one.
  /// [wantedArtist], when given, is matched against each candidate's subtitle
  /// (search rows carry "Album • Artist • Year") — without this, a query like
  /// "Death Race For Love (Bonus Track Version) Juice WRLD" could title-match
  /// an unrelated album by a different artist that happens to share a short
  /// substring (e.g. "Death Race"), since title-only scoring has no way to
  /// tell the two apart.
  String? _pickAlbumId(dynamic data, String wantedAlbum, [String? wantedArtist]) {
    final renderers = <Map>[];
    _collectByKey(data, 'musicResponsiveListItemRenderer', renderers);
    _collectByKey(data, 'musicTwoRowItemRenderer', renderers);
    final want = wantedAlbum.toLowerCase().trim();
    final wantArtist = wantedArtist?.toLowerCase().trim() ?? '';
    String? best;
    double bestScore = -1;
    for (final r in renderers) {
      final id = _findBrowseId(r, 'MPRE');
      if (id == null) continue;
      final title = _rendererTitle(r).toLowerCase().trim();
      if (title.isEmpty) continue;
      final subtitle = _rendererSubtitle(r).toLowerCase();
      final score = _albumScore(title, want, subtitle, wantArtist);
      if (score > bestScore) {
        bestScore = score;
        best = id;
      }
    }
    return best;
  }

  double _albumScore(String candidate, String want, String candidateSubtitle, String wantArtist) {
    double score = 0;
    if (candidate == want) {
      score += 100;
    } else if (candidate.contains(want) || want.contains(candidate)) {
      score += 50;
    }
    const editionWords = ['deluxe', 'expanded', 'video', 'edition', 'anniversary'];
    final candidateHasEdition = editionWords.any((w) => candidate.contains(w));
    final wantHasEdition = editionWords.any((w) => want.contains(w));
    if (candidateHasEdition && !wantHasEdition) score -= 40; // prefer standard
    // Prefer the closest length (fewer extra words) as a tiebreaker.
    score -= (candidate.length - want.length).abs() * 0.1;
    // Artist match is decisive — a title-only tie between two same-ish-named
    // albums by different artists must not be broken by search-result order.
    if (wantArtist.isNotEmpty && candidateSubtitle.isNotEmpty) {
      if (candidateSubtitle.contains(wantArtist)) {
        score += 60;
      } else {
        score -= 60;
      }
    }
    return score;
  }

  /// Subtitle text of a search-result renderer (list row or two-row card) —
  /// typically "Album • Artist • Year", the only place artist name appears
  /// alongside an album search result.
  String _rendererSubtitle(Map r) {
    final flex = r['flexColumns'];
    if (flex is List && flex.length > 1) {
      final runs = flex[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
      if (runs is List) return runs.map((e) => e?['text']?.toString() ?? '').join();
    }
    return _runsText(r['subtitle']);
  }

  /// Title of a search-result renderer (list row or two-row card).
  String _rendererTitle(Map r) {
    final flex = r['flexColumns'];
    if (flex is List && flex.isNotEmpty) {
      final runs = flex[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
      if (runs is List && runs.isNotEmpty) return runs[0]?['text']?.toString() ?? '';
    }
    return _runsText(r['title']);
  }

  /// Returns the first value found under any of [keys] (depth-first).
  dynamic _findFirstOfKey(dynamic node, List<String> keys) {
    if (node is Map) {
      for (final k in keys) {
        if (node[k] != null) return node[k];
      }
      for (final v in node.values) {
        final r = _findFirstOfKey(v, keys);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findFirstOfKey(v, keys);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// The album/detail HEADER thumbnail specifically (not any thumbnail in the tree).
  String? _findHeaderThumbnail(dynamic node) {
    if (node is Map) {
      for (final headerKey in const ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer']) {
        final h = node[headerKey];
        if (h is Map) {
          final t = _findFirstThumbnail(h['thumbnail'] ?? h);
          if (t != null) return t;
        }
      }
      for (final v in node.values) {
        final r = _findHeaderThumbnail(v);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findHeaderThumbnail(v);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Resolves an album's own watch-playlist id (OLAK5uy…/VL…, V4.5 pivot) for
  /// native triggering via [CollabService.playNativeMix] — same idea as
  /// [getArtistRadioPlaylistId], just for albums. Looks for the id on the
  /// album header's PLAY/SHUFFLE button first (most reliable — every track row
  /// also carries the same playlistId, so a generic recursive search works too,
  /// just with header priority to avoid grabbing something from a nested shelf).
  Future<String?> getAlbumPlaylistId(String album, String artist) async {
    try {
      final data = await _innertubePost('search', {'query': '$album $artist'.trim()});
      final albumId = _pickAlbumId(data, album, artist) ?? _findBrowseId(data, 'MPRE');
      if (albumId == null) {
        debugPrint('getAlbumPlaylistId: no album browseId for "$album $artist"');
        return null;
      }
      final browse = await _innertubePost('browse', {'browseId': albumId});
      final header = _findFirstOfKey(browse, const ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer']);
      final playlistId = _findAnyPlaylistId(header) ?? _findAnyPlaylistId(browse);
      if (playlistId == null) {
        debugPrint('getAlbumPlaylistId: no playlistId for "$album $artist" (browse $albumId)');
      }
      return playlistId;
    } catch (e) {
      debugPrint('getAlbumPlaylistId failed: $e');
      return null;
    }
  }

  /// Resolves just the RD… radio playlist id for an artist (V4.5 pivot — the
  /// caller triggers it NATIVELY via [CollabService.playNativeMix] instead of
  /// this service expanding it into a track list itself).
  Future<String?> getArtistRadioPlaylistId(String artist) async {
    try {
      final data = await _innertubePost('search', {'query': artist});
      // Artist browseIds are channel ids ("UC...").
      final artistId = _findBrowseId(data, 'UC');
      if (artistId == null) {
        debugPrint('getArtistRadioPlaylistId: no artist browseId for "$artist"');
        return null;
      }
      final browse = await _innertubePost('browse', {'browseId': artistId});
      // Radio/shuffle playlist ids start with "RD".
      final radioId = _findRadioPlaylistId(browse);
      if (radioId == null) {
        debugPrint('getArtistRadioPlaylistId: no radio playlist for "$artist"');
      }
      return radioId;
    } catch (e) {
      debugPrint('getArtistRadioPlaylistId failed: $e');
      return null;
    }
  }

  /// Resolves the artist's own "Songs" playlist id (VLOLAK5uy…, via the same
  /// [_findSongsPlaylistId] shelf lookup [getArtistTracks] uses) for native
  /// triggering via [CollabService.playNativeMix] — "artist only" mode (not
  /// radio). Native means YT Music plays it in its own playlist order; the
  /// app-side weighted-random shuffle [getArtistTracks] does is not applied.
  Future<String?> getArtistSongsPlaylistId(String artist) async {
    try {
      final data = await _innertubePost('search', {'query': artist});
      final artistId = _findBrowseId(data, 'UC');
      if (artistId == null) {
        debugPrint('getArtistSongsPlaylistId: no artist browseId for "$artist"');
        return null;
      }
      final browse = await _innertubePost('browse', {'browseId': artistId});
      final songsId = _findSongsPlaylistId(browse);
      if (songsId == null) {
        debugPrint('getArtistSongsPlaylistId: no songs playlist for "$artist"');
        return null;
      }
      // _findSongsPlaylistId returns a BROWSE id ("VLOLAK5uy…" — for paging
      // through the shelf), not a watch-playlist id — strip the "VL" so
      // playNativeMix's list= param resolves (same normalization the home-tile
      // mix path applies to its browseEndpoint.browseId case, main.dart's
      // `pid.startsWith('VL') ? pid.substring(2) : pid`). Confirmed on-device:
      // passing the raw "VL…" id let playFromUri report success but YT Music
      // silently failed to load it and kept playing whatever was already on.
      return songsId.startsWith('VL') ? songsId.substring(2) : songsId;
    } catch (e) {
      debugPrint('getArtistSongsPlaylistId failed: $e');
      return null;
    }
  }

  // --- Personalized home feed (authenticated) → mix tiles ---------------------
  //
  // ⚠️ Best-effort parse of FEmusic_home; TUNE against the real JSON on-device
  // (see debugDumpHome). Returns []/keeps prior tiles on any failure.

  /// Fetches the personalized home feed and selects up to 4 mix tiles, with
  /// Supermix pinned first, then a stable preferred set, then feed order.
  Future<List<HomeTile>> fetchHomeTiles() async {
    if (!isYtmLoggedIn) {
      homeTiles = [];
      notifyListeners();
      return homeTiles;
    }
    try {
      final data = await _innertubePost('browse', {'browseId': 'FEmusic_home'});
      if (data == null) return homeTiles;

      // Playlist/mix cards (two-row items) that carry a playable id.
      final cards = <Map>[];
      _collectByKey(data, 'musicTwoRowItemRenderer', cards);
      final candidates = <HomeTile>[];
      final seen = <String>{};
      for (final c in cards) {
        final title = _rendererTitle(c).trim();
        if (title.isEmpty) continue;
        final nav = c['navigationEndpoint'];
        final pid = (nav?['watchPlaylistEndpoint']?['playlistId'] ??
                nav?['browseEndpoint']?['browseId'])
            ?.toString();
        if (pid == null || pid.isEmpty || seen.contains(pid)) continue;
        // Only playable playlists/mixes — skip artist (UC…) / album (MPRE…) cards.
        if (!(pid.startsWith('RD') || pid.startsWith('VL') || pid.startsWith('OLAK') || pid.startsWith('PL'))) {
          continue;
        }
        seen.add(pid);
        candidates.add(HomeTile(title: title, thumbnail: _findFirstThumbnail(c) ?? '', playlistId: pid));
      }

      // Best-effort "Quick picks" shelf (individual songs, not a card). This
      // shelf is flakier than the mix cards above — YT Music sometimes omits
      // it from a given FEmusic_home response even when logged in with a
      // healthy feed — so retry once with a fresh browse call before giving
      // up, since a re-fetch often does surface it (per user reports of
      // Quick Picks "sometimes" missing).
      var qp = _quickPicksTile(data);
      if (qp == null) {
        final retryData = await _innertubePost('browse', {'browseId': 'FEmusic_home'});
        if (retryData != null) qp = _quickPicksTile(retryData);
      }
      if (qp != null) candidates.insert(0, qp);

      // Select a stable set of 4. Supermix and Quick Picks are force-selected
      // first (each parsed via an independent path — a card match vs. the
      // separate `_quickPicksTile` shelf scan — so one succeeding is not a
      // signal the other will; without forcing both, a lower-priority tile
      // could otherwise bump a successfully-parsed Quick Picks out of the 4).
      const forcedPrefs = ['supermix', 'quick picks'];
      const prefs = ['discover mix', 'new release mix', 'my mix', 'listen again'];
      final selected = <HomeTile>[];
      final used = <String>{};
      String key(HomeTile t) => t.playlistId ?? t.title;
      for (final p in forcedPrefs) {
        for (final c in candidates) {
          if (used.contains(key(c))) continue;
          if (c.title.toLowerCase().contains(p)) {
            selected.add(c);
            used.add(key(c));
            break;
          }
        }
      }
      for (final p in prefs) {
        for (final c in candidates) {
          if (used.contains(key(c))) continue;
          if (c.title.toLowerCase().contains(p)) {
            selected.add(c);
            used.add(key(c));
            break;
          }
        }
        if (selected.length >= 4) break;
      }
      for (final c in candidates) {
        if (selected.length >= 4) break;
        if (!used.contains(key(c))) {
          selected.add(c);
          used.add(key(c));
        }
      }

      homeTiles = selected.take(4).toList();
      debugPrint('fetchHomeTiles: ${candidates.length} candidates → ${homeTiles.length} tiles '
          '[${homeTiles.map((t) => t.title).join(", ")}]');
      notifyListeners();
      return homeTiles;
    } catch (e) {
      debugPrint('fetchHomeTiles failed: $e');
      return homeTiles;
    }
  }

  /// Builds a "Quick picks" tile from its song shelf, if present.
  HomeTile? _quickPicksTile(dynamic data) {
    final shelves = <Map>[];
    _collectByKey(data, 'musicCarouselShelfRenderer', shelves);
    for (final s in shelves) {
      final title = _runsText(s['header']?['musicCarouselShelfBasicHeaderRenderer']?['title']);
      if (!title.toLowerCase().contains('quick picks')) continue;
      final rows = <Map>[];
      _collectByKey(s, 'musicResponsiveListItemRenderer', rows);
      final songs = <Map<String, String>>[];
      for (final r in rows) {
        final parsed = _parseSongRenderer(r);
        if (parsed != null) songs.add(parsed);
      }
      if (songs.isNotEmpty) {
        return HomeTile(title: title, thumbnail: songs.first['thumbnail'] ?? '', songs: songs);
      }
    }
    return null;
  }

  /// The curated song list for a tile that has one (Quick Picks — individual
  /// songs, not a playlist/mix id). Tiles with a `playlistId` (Supermix,
  /// Discover Mix, …) are triggered NATIVELY instead (V4.5 pivot — see
  /// `_playMix` in main.dart / [CollabService.playNativeMix]), so this no
  /// longer expands `playlistId` tiles into a track list itself.
  List<Map<String, String>> getMixTracks(HomeTile tile) => tile.songs ?? [];

  /// Fetches the artist's OWN songs (not radio) — as many as YT Music exposes —
  /// in a weighted-random order (popular songs favored early, different each
  /// call). Returns [] on failure so the caller falls back to the YT Music launch.
  Future<List<Map<String, String>>> getArtistTracks(String artist) async {
    try {
      final data = await _innertubePost('search', {'query': artist});
      final artistId = _findBrowseId(data, 'UC'); // channel id
      if (artistId == null) {
        debugPrint('getArtistTracks: no artist browseId for "$artist"');
        return [];
      }
      final browse = await _innertubePost('browse', {'browseId': artistId});
      // Prefer the full "Songs" playlist; fall back to the artist page's shelf.
      final songsPlaylistId = _findSongsPlaylistId(browse);
      final scoped = songsPlaylistId != null;
      dynamic root = browse;
      if (scoped) {
        final pl = await _innertubePost('browse', {'browseId': songsPlaylistId});
        if (pl != null) root = pl;
      }
      final renderers = <Map>[];
      _collectByKey(root, 'musicResponsiveListItemRenderer', renderers);
      final aLower = artist.toLowerCase().trim();
      final tracks = <Map<String, String>>[];
      final seen = <String>{};
      for (final r in renderers) {
        final parsed = _parseSongRenderer(r);
        if (parsed == null) continue;
        final vid = parsed['videoId']!;
        if (seen.contains(vid)) continue;
        // On the artist page (not the dedicated Songs playlist) other shelves
        // ("fans might also like") leak in — keep only this artist's rows.
        if (!scoped) {
          final rowArtist = (parsed['artist'] ?? '').toLowerCase();
          if (rowArtist.isNotEmpty && aLower.isNotEmpty &&
              !rowArtist.contains(aLower) && !aLower.contains(rowArtist)) {
            continue;
          }
        }
        if ((parsed['artist'] ?? '').isEmpty) parsed['artist'] = artist;
        seen.add(vid);
        tracks.add(parsed);
      }
      _weightedShuffle(tracks);
      debugPrint('getArtistTracks: "$artist" → ${tracks.length} tracks (weighted-random)');
      return tracks;
    } catch (e) {
      debugPrint('getArtistTracks failed: $e');
      return [];
    }
  }

  /// Weighted-random reorder (Efraimidis–Spirakis): earlier (more popular) items
  /// get a higher weight so they trend toward the front, but a fresh random key
  /// each call means a different order every time.
  void _weightedShuffle(List<Map<String, String>> items) {
    final n = items.length;
    if (n <= 1) return;
    final keyed = <MapEntry<double, Map<String, String>>>[];
    for (int i = 0; i < n; i++) {
      final w = (n - i).toDouble(); // rank 0 = most popular = highest weight
      final u = _rng.nextDouble().clamp(1e-9, 1.0);
      keyed.add(MapEntry(math.pow(u, 1.0 / w).toDouble(), items[i]));
    }
    keyed.sort((a, b) => b.key.compareTo(a.key)); // descending
    for (int i = 0; i < n; i++) {
      items[i] = keyed[i].value;
    }
  }

  /// Finds the artist page's songs shelf (titled "Songs" or "Top songs") and
  /// returns its full-songs playlist browseId (VLOLAK5uy_…), so we get the whole
  /// list (~100) rather than just the ~5 shown inline on the artist page.
  String? _findSongsPlaylistId(dynamic node) {
    if (node is Map) {
      final shelf = node['musicShelfRenderer'];
      if (shelf is Map) {
        final titleRuns = shelf['title']?['runs'];
        if (titleRuns is List && titleRuns.isNotEmpty) {
          final t = (titleRuns[0]?['text'] ?? '').toString().toLowerCase();
          if (t.contains('song')) {
            // The full-list link lives on the shelf title's nav or bottomEndpoint.
            final bid = titleRuns[0]?['navigationEndpoint']?['browseEndpoint']?['browseId'] ??
                shelf['bottomEndpoint']?['browseEndpoint']?['browseId'];
            if (bid is String && bid.isNotEmpty) return bid;
          }
        }
      }
      for (final v in node.values) {
        final r = _findSongsPlaylistId(v);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findSongsPlaylistId(v);
        if (r != null) return r;
      }
    }
    return null;
  }

  // Recursive helpers for walking the deeply-nested Innertube JSON.
  String? _findBrowseId(dynamic node, String prefix) {
    if (node is Map) {
      final b = node['browseId'];
      if (b is String && b.startsWith(prefix)) return b;
      for (final v in node.values) {
        final r = _findBrowseId(v, prefix);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findBrowseId(v, prefix);
        if (r != null) return r;
      }
    }
    return null;
  }

  String? _findRadioPlaylistId(dynamic node) {
    if (node is Map) {
      final p = node['playlistId'];
      if (p is String && p.startsWith('RD')) return p;
      for (final v in node.values) {
        final r = _findRadioPlaylistId(v);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findRadioPlaylistId(v);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Finds the first `playlistId` under [node] with a "real playlist" prefix
  /// (VL/OLAK/PL — excludes radio RD… ids, which [_findRadioPlaylistId] handles).
  String? _findAnyPlaylistId(dynamic node) {
    if (node is Map) {
      final p = node['playlistId'];
      if (p is String && (p.startsWith('VL') || p.startsWith('OLAK') || p.startsWith('PL'))) return p;
      for (final v in node.values) {
        final r = _findAnyPlaylistId(v);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findAnyPlaylistId(v);
        if (r != null) return r;
      }
    }
    return null;
  }

  String? _findFirstThumbnail(dynamic node) {
    if (node is Map) {
      final t = node['thumbnails'];
      if (t is List && t.isNotEmpty && t.last is Map && t.last['url'] != null) {
        return t.last['url'].toString().replaceAll(RegExp(r'=w\d+-h\d+'), '=w400-h400');
      }
      for (final v in node.values) {
        final r = _findFirstThumbnail(v);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findFirstThumbnail(v);
        if (r != null) return r;
      }
    }
    return null;
  }

  void _collectByKey(dynamic node, String key, List<Map> out) {
    if (node is Map) {
      final v = node[key];
      if (v is Map) out.add(v);
      for (final val in node.values) {
        _collectByKey(val, key, out);
      }
    } else if (node is List) {
      for (final val in node) {
        _collectByKey(val, key, out);
      }
    }
  }

  String _runsText(dynamic textObj) {
    if (textObj is Map) {
      final runs = textObj['runs'];
      if (runs is List) return runs.map((r) => (r is Map ? r['text'] ?? '' : '')).join('');
      return textObj['simpleText']?.toString() ?? '';
    }
    return '';
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

      await _saveQueue();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint("Error adding song to local queue: $e");
      return false;
    } finally {
      _isAdding = false;
    }
  }

  /// Adds an already-resolved song (exact YT Music videoId + metadata, e.g. a
  /// result the passenger picked from the PWA search list) directly to the queue,
  /// skipping any re-search so the added song matches exactly what was shown.
  Future<bool> addResolvedSong({
    required String videoId,
    required String title,
    String artist = '',
    String thumbnail = '',
  }) {
    return _addResolvedSong({
      'videoId': videoId,
      'title': title.isNotEmpty ? title : 'Unknown',
      'artist': artist,
      'thumbnail': thumbnail,
    }, originalVideoId: videoId);
  }

  /// Replaces the entire queue with a resolved list of songs (album tracks,
  /// artist radio, or a single favorite). Assigns fresh local ids and persists.
  Future<void> replaceQueue(List<Map<String, String>> songs) async {
    final base = DateTime.now().millisecondsSinceEpoch;
    currentQueue = List.generate(songs.length, (i) {
      final s = songs[i];
      final vid = s['videoId'] ?? '';
      return <String, dynamic>{
        'id': '${base + i}',
        'videoId': vid,
        'originalVideoId': vid,
        'title': s['title'] ?? 'Unknown',
        'artist': s['artist'] ?? '',
        'thumbnail': s['thumbnail'] ?? '',
        // Retained so the queue can background-swap video (OMV) ids for audio.
        'videoType': s['videoType'] ?? '',
      };
    });
    await _saveQueue();
    notifyListeners();
  }

  /// Resolves a track's audio-only (ATV) videoId via a Songs search. Returns null
  /// if no confident audio match is found. Used to swap album video ids for audio.
  Future<String?> resolveAudioVideoId(String title, String artist) async {
    if (title.trim().isEmpty) return null;
    try {
      final results = await searchYTMusicSongs('$title $artist', limit: 3)
          .timeout(const Duration(seconds: 6));
      final want = title.toLowerCase();
      for (final r in results) {
        if (!(r['videoType'] ?? '').contains('ATV')) continue;
        final rt = (r['title'] ?? '').toLowerCase();
        if (rt == want || rt.contains(want) || want.contains(rt)) {
          final vid = r['videoId'] ?? '';
          if (vid.isNotEmpty) return vid;
        }
      }
    } catch (_) {/* keep the original id on failure */}
    return null;
  }

  /// Updates a queue item's playable videoId (e.g. after audio re-resolution)
  /// and marks it resolved so it isn't re-processed. Persists + notifies.
  Future<void> setQueueItemVideoId(int index, String videoId) async {
    if (index < 0 || index >= currentQueue.length) return;
    currentQueue[index]['videoId'] = videoId;
    currentQueue[index]['videoType'] = 'MUSIC_VIDEO_TYPE_ATV';
    notifyListeners();
    await _saveQueue();
  }

  Future<void> clearPlaylist() async {
    currentQueue.clear();
    await _saveQueue();
    notifyListeners();
  }

  Future<void> fetchQueue() async {
    // No longer an API fetch, just notify listeners of local state.
    notifyListeners();
  }

  Future<void> deleteSong(String playlistItemId) async {
    currentQueue.removeWhere((item) => item['id'] == playlistItemId);
    await _saveQueue();
    notifyListeners();
  }

  Future<void> reorderSong(String playlistItemId, int newPosition) async {
    final index = currentQueue.indexWhere((item) => item['id'] == playlistItemId);
    if (index != -1) {
      final item = currentQueue.removeAt(index);
      currentQueue.insert(newPosition.clamp(0, currentQueue.length), item);
      await _saveQueue();
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
