import re

with open('lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update Geolocator accuracy and remove distanceFilter
loc_old = '''    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position position) {'''

loc_new = '''    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((Position position) {'''

content = content.replace(loc_old, loc_new)

# 2. Update Overpass API query and headers
speed_old = '''        final query = '[out:json];way(around:50,$lat,$lon)["maxspeed"];out tags;';
        final url = Uri.parse('https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}');
        
        final response = await http.get(url).timeout(const Duration(seconds: 5));'''

speed_new = '''        final query = '[out:json];way(around:100,$lat,$lon)["maxspeed"];out tags;';
        final url = Uri.parse('https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}');
        
        final response = await http.get(url, headers: {'User-Agent': 'CarDashboardApp/1.0'}).timeout(const Duration(seconds: 5));'''

content = content.replace(speed_old, speed_new)

# 3. Add media position and duration to DashboardProvider
vars_old = '''  bool get isKmph => _isKmph;
  double get speed => _speed;
  double get altitude => _altitude;
  double get heading => _heading;
  String get streetName => _streetName;'''

vars_new = '''  double _mediaPosition = 0.0;
  double _mediaDuration = 1.0;

  bool get isKmph => _isKmph;
  double get speed => _speed;
  double get altitude => _altitude;
  double get heading => _heading;
  String get streetName => _streetName;
  double get mediaPosition => _mediaPosition;
  double get mediaDuration => _mediaDuration;'''

content = content.replace(vars_old, vars_new)

# 4. Poll getMediaProgress
poll_old = '''           if (title != _currentTrack || artist != _currentArtist || _isPlaying != isCurrentlyPlaying) {
              if (title.isNotEmpty) _currentTrack = title;
              if (artist.isNotEmpty) _currentArtist = artist;
              _isPlaying = isCurrentlyPlaying;
              notifyListeners();
              
              if (title.isNotEmpty && title != 'Not Playing') {
                 final newThumb = await fetchAlbumArt(title, artist);
                 if (newThumb.isNotEmpty) {
                     _currentThumbnailUrl = newThumb;
                     notifyListeners();
                 }
              }
           }
        }
      } catch (e) {
        // Ignored
      }
    });'''

poll_new = '''           if (title != _currentTrack || artist != _currentArtist || _isPlaying != isCurrentlyPlaying) {
              if (title.isNotEmpty) _currentTrack = title;
              if (artist.isNotEmpty) _currentArtist = artist;
              _isPlaying = isCurrentlyPlaying;
              notifyListeners();
              
              if (title.isNotEmpty && title != 'Not Playing') {
                 final newThumb = await fetchAlbumArt(title, artist);
                 if (newThumb.isNotEmpty) {
                     _currentThumbnailUrl = newThumb;
                     notifyListeners();
                 }
              }
           }
        }
        
        // Poll exact media progress from Native
        final Map<dynamic, dynamic>? progress = await platform.invokeMethod('getMediaProgress');
        if (progress != null) {
           _mediaPosition = (progress['position'] as int).toDouble();
           _mediaDuration = (progress['duration'] as int).toDouble();
           if (_mediaDuration <= 0) _mediaDuration = 1.0; // Prevent divide by zero
           notifyListeners();
        }
      } catch (e) {
        // Ignored
      }
    });'''

content = content.replace(poll_old, poll_new)

with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)
