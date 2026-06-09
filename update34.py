import re

with open('lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add Uint8List to imports and DashboardProvider
import_old = '''import 'dart:async';
import 'dart:convert';
import 'dart:io';'''
import_new = '''import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';'''
content = content.replace(import_old, import_new)

vars_old = '''  double _mediaDuration = 1.0;

  bool get isKmph => _isKmph;'''
vars_new = '''  double _mediaDuration = 1.0;
  Uint8List? _currentAlbumArtBytes;

  bool get isKmph => _isKmph;'''
content = content.replace(vars_old, vars_new)

getter_old = '''  double get mediaDuration => _mediaDuration;'''
getter_new = '''  double get mediaDuration => _mediaDuration;
  Uint8List? get currentAlbumArtBytes => _currentAlbumArtBytes;'''
content = content.replace(getter_old, getter_new)

# 2. Replace fetchAlbumArt with _fetchNativeAlbumArt
fetch_old = '''  Future<String> fetchAlbumArt(String track, String artist) async {
    try {
      // Use Deezer API for better album art accuracy
      final query = Uri.encodeComponent('track:"$track" artist:"$artist"');
      var url = Uri.parse('https://api.deezer.com/search?q=$query&limit=1');
      var client = HttpClient();
      var request = await client.getUrl(url);
      var response = await request.close();
      
      if (response.statusCode == 200) {
        var stringData = await response.transform(utf8.decoder).join();
        var json = jsonDecode(stringData);
        if (json['data'] != null && json['data'].isNotEmpty) {
          return json['data'][0]['album']['cover_xl'] ?? json['data'][0]['album']['cover_big'] ?? '';
        }
      }
      
      // Fallback to generic search if strict search fails
      final looseQuery = Uri.encodeComponent('$track $artist');
      url = Uri.parse('https://api.deezer.com/search?q=$looseQuery&limit=1');
      request = await client.getUrl(url);
      response = await request.close();
      
      if (response.statusCode == 200) {
        var stringData = await response.transform(utf8.decoder).join();
        var json = jsonDecode(stringData);
        if (json['data'] != null && json['data'].isNotEmpty) {
          return json['data'][0]['album']['cover_xl'] ?? json['data'][0]['album']['cover_big'] ?? '';
        }
      }
    } catch (e) {
      debugPrint("Error fetching album art from Deezer: $e");
    }
    return '';
  }'''

fetch_new = '''  Future<void> _fetchNativeAlbumArt() async {
    try {
      final Uint8List? artBytes = await platform.invokeMethod('getMediaArt');
      if (artBytes != null) {
        _currentAlbumArtBytes = artBytes;
        notifyListeners();
      } else {
        _currentAlbumArtBytes = null;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error fetching native album art: $e");
    }
  }'''
content = content.replace(fetch_old, fetch_new)

# 3. Update _startMediaPolling to use _fetchNativeAlbumArt
poll_old = '''              if (title.isNotEmpty && title != 'Not Playing') {
                 final newThumb = await fetchAlbumArt(title, artist);
                 if (newThumb.isNotEmpty) {
                     _currentThumbnailUrl = newThumb;
                     notifyListeners();
                 }
              }'''
poll_new = '''              if (title.isNotEmpty && title != 'Not Playing') {
                 await _fetchNativeAlbumArt();
              } else {
                 _currentAlbumArtBytes = null;
              }'''
content = content.replace(poll_old, poll_new)

with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)
