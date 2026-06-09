import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_media_controller/flutter_media_controller.dart';
import 'speedometer_widget.dart';
import 'theme/dynamic_theme.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'ui/settings_dialog.dart';
import 'ui/sidebar_tabs.dart';
import 'ui/phone_tab.dart';
import 'package:share_handler/share_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set preferred orientation to landscape only
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Hide system status and navigation bars for immersive in-car dashboard experience
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DashboardProvider()..initialize()),
        ChangeNotifierProvider(create: (_) => DynamicThemeProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dynamicTheme = Provider.of<DynamicThemeProvider>(context);
    
    return MaterialApp(
      title: 'Car Dashboard',
      debugShowCheckedModeBanner: false,
      theme: dynamicTheme.currentTheme,
      home: const DashboardScreen(),
    );
  }
}

class DashboardProvider with ChangeNotifier {
  bool _isKmph = true;
  bool _isDemoMode = false;
  bool _isPlaying = false;
  LocationPermission _permission = LocationPermission.denied;
  bool _serviceEnabled = false;
  String _errorMessage = '';

  // Favorites state variables
  List<Map<String, String>> _favorites = [
    {'title': 'My Supermix', 'url': 'My Supermix'},
    {'title': 'Chill Beats', 'url': 'Chill Beats'},
    {'title': 'Driving Anthems', 'url': 'Driving Anthems'},
  ];
  Map<String, String>? _pendingSharedFavorite;
  
  List<Map<String, String>> get favorites => _favorites;
  Map<String, String>? get pendingSharedFavorite => _pendingSharedFavorite;

  // Now Playing state variables
  String _currentTrack = 'Not Playing';
  String _currentArtist = 'Waiting for media...';
  String _currentAlbum = '';
  String _currentThumbnailUrl = '';
  bool _waitingForMusicToReturn = false;
  bool _canDrawOverlays = false;
  bool _hasNotificationAccess = false;
  
  // Call state variables
  String _callState = 'IDLE';
  String _callNumber = '';
  String _callName = '';
  int _callDurationSeconds = 0;
  bool _hasPhonePermissions = false;
  
  bool _dashcamRecording = false;
  String _speedLimit = '?';
  Position? _lastSpeedLimitPosition;
  double _speed = 0.0;
  double _altitude = 0.0;
  double _heading = 0.0;
  String _streetName = 'Scanning...';

  double _mediaPosition = 0.0;
  double _mediaDuration = 1.0;
  Uint8List? _currentAlbumArtBytes;

  bool get isKmph => _isKmph;
  double get speed => _speed;
  double get altitude => _altitude;
  double get heading => _heading;
  String get streetName => _streetName;
  double get mediaPosition => _mediaPosition;
  double get mediaDuration => _mediaDuration;
  Uint8List? get currentAlbumArtBytes => _currentAlbumArtBytes;
  bool get hasLocationPermission => _permission == LocationPermission.whileInUse || _permission == LocationPermission.always;
  bool get canDrawOverlays => _canDrawOverlays;
  bool get hasNotificationAccess => _hasNotificationAccess;
  
  String get callState => _callState;
  String get callNumber => _callNumber;
  String get callName => _callName;
  int get callDurationSeconds => _callDurationSeconds;
  bool get hasPhonePermissions => _hasPhonePermissions;
  
  bool get dashcamRecording => _dashcamRecording;
  String get speedLimit => _speedLimit;
  bool get isDemoMode => _isDemoMode;
  bool get isPlaying => _isPlaying;
  LocationPermission get permission => _permission;
  bool get serviceEnabled => _serviceEnabled;
  String get errorMessage => _errorMessage;

  String get currentTrack => _currentTrack;
  String get currentArtist => _currentArtist;
  String get currentAlbum => _currentAlbum;
  String get currentThumbnailUrl => _currentThumbnailUrl;

  int _selectedSidebarTab = 0; // 0=Media, 1=Phone, 2=Notifications
  bool _userManuallySwitchedTab = false;

  int get selectedSidebarTab => _selectedSidebarTab;

  void setSidebarTab(int index, {bool isManual = false}) {
    if (isManual) {
      _userManuallySwitchedTab = true;
    }
    if (_selectedSidebarTab != index) {
      _selectedSidebarTab = index;
      notifyListeners();
    }
  }

  Timer? _mediaTimer;

  void toggleUnit() {
    _isKmph = !_isKmph;
    notifyListeners();
  }

  Timer? _demoTimer;
  
  void toggleDemoMode() {
    _isDemoMode = !_isDemoMode;
    if (_isDemoMode) {
       _speed = 0.0;
       _demoTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
          _speed += 0.5; // slow acceleration
          if (_speed > 40.0) _speed = 40.0; // max ~144 km/h
          _altitude = 650.0 + _speed;
          _heading = (_heading + 1.5) % 360;
          _streetName = "King Fahd Road";
          notifyListeners();
       });
       _errorMessage = '';
    } else {
       _demoTimer?.cancel();
       _speed = 0.0;
       checkLocationSettingsAndPermissions();
    }
    notifyListeners();
  }

  void setPlaying(bool state) {
    _isPlaying = state;
    notifyListeners();
  }

  Future<void> requestMediaPermissions() async {
    try {
      await FlutterMediaController.requestPermissions();
    } catch (e) {
      debugPrint("Media perm error: $e");
    }
  }

  Future<void> _fetchNativeAlbumArt() async {
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
  }

  StreamSubscription<Position>? _positionStreamSubscription;

  Future<void> initialize() async {
    checkPermissions();
    await checkLocationSettingsAndPermissions();
    _startLocationUpdates();
    _startMediaPolling();
    _startDashcamPolling();
    
    await loadFavorites();
    initShareHandler();

    // Listen for call state updates from Android native
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onCallStateChanged') {
        final Map? args = call.arguments as Map?;
        if (args != null) {
          if (args.containsKey('stateInt')) {
            final stateInt = args['stateInt'] as int? ?? 7; // 7 is DISCONNECTED
            final number = args['number'] as String? ?? '';
            _handleCallStateChange(stateInt, number);
          } else if (args.containsKey('state')) {
            final stateStr = args['state'] as String? ?? 'IDLE';
            final number = args['number'] as String? ?? '';
            int stateInt = 7;
            if (stateStr == 'RINGING') stateInt = 2;
            else if (stateStr == 'OFFHOOK') stateInt = 4;
            _handleCallStateChange(stateInt, number);
          }
        }
      }
    });

    await checkPhonePermissions();
  }

  Timer? _callDurationTimer;
  DateTime? _callStartTime;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  void _handleCallStateChange(int stateInt, String number) async {
    // 0: NEW, 1: DIALING, 2: RINGING, 3: HOLDING, 4: ACTIVE, 7: DISCONNECTED
    String stateStr = 'IDLE';
    if (stateInt == 1) stateStr = 'DIALING';
    else if (stateInt == 2) stateStr = 'RINGING';
    else if (stateInt == 4) stateStr = 'ACTIVE';
    else if (stateInt == 7) stateStr = 'IDLE';
    else if (stateInt == 0 || stateInt == 3) stateStr = 'CONNECTING';

    _callState = stateStr;
    
    if (stateStr == 'IDLE') {
      _callNumber = '';
      _callName = '';
      _callDurationSeconds = 0;
      _callDurationTimer?.cancel();
      _callDurationTimer = null;
      _callStartTime = null;
      _isMuted = false;
    } else {
      _callNumber = number;
      
      // Resolve caller contact name if we haven't already
      if (_callNumber.isNotEmpty && (_callName.isEmpty || _callName == 'Unknown Caller')) {
        _callName = await _resolveContactName(_callNumber);
      } else if (_callNumber.isEmpty) {
        _callName = 'Unknown Caller';
      }
      
      if (stateStr == 'ACTIVE') {
        if (_callStartTime == null) {
          _callStartTime = DateTime.now();
          _callDurationTimer?.cancel();
          _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            if (_callStartTime != null) {
              _callDurationSeconds = DateTime.now().difference(_callStartTime!).inSeconds;
              notifyListeners();
            }
          });
        }
      }
    }
    notifyListeners();
  }

  Future<String> _resolveContactName(String number) async {
    try {
      final cleanNumber = number.replaceAll(RegExp(r'\D'), '');
      if (cleanNumber.isEmpty) return 'Unknown Caller';
      
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      if (status != PermissionStatus.granted) {
        return number.isNotEmpty ? number : 'Unknown Caller';
      }
      
      final contacts = await FlutterContacts.getAll(properties: ContactProperties.all);
      for (final contact in contacts) {
        for (final phone in contact.phones) {
          final cleanPhone = phone.number.replaceAll(RegExp(r'\D'), '');
          
          if (cleanPhone.isNotEmpty && cleanNumber.isNotEmpty) {
            String suffixContact = cleanPhone.length > 7 ? cleanPhone.substring(cleanPhone.length - 7) : cleanPhone;
            String suffixIncoming = cleanNumber.length > 7 ? cleanNumber.substring(cleanNumber.length - 7) : cleanNumber;
            
            if (suffixContact == suffixIncoming) {
              final name = contact.displayName;
              return (name != null && name.isNotEmpty) ? name : (number.isNotEmpty ? number : 'Unknown Caller');
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Resolve contact name error: $e");
    }
    return number.isNotEmpty ? number : 'Unknown Caller';
  }

  Future<void> answerCall() async {
    try {
      await platform.invokeMethod('answerCall');
    } catch (e) {
      debugPrint("Answer call failed: $e");
    }
  }

  Future<void> endCall() async {
    try {
      await platform.invokeMethod('endCall');
    } catch (e) {
      debugPrint("End call failed: $e");
    }
  }

  Future<void> makeCall(String number) async {
    try {
      await platform.invokeMethod('makeCall', {'number': number});
    } catch (e) {
      debugPrint("Make call failed: $e");
    }
  }

  bool _isDefaultDialer = false;
  bool get isDefaultDialer => _isDefaultDialer;

  Future<void> checkPhonePermissions() async {
    try {
      final bool hasPerms = await platform.invokeMethod('checkPhonePermissions');
      _hasPhonePermissions = hasPerms;
      
      final bool isDefault = await platform.invokeMethod('isDefaultDialer');
      _isDefaultDialer = isDefault;
      
      notifyListeners();
    } catch (e) {
      debugPrint("Check phone permissions error: $e");
    }
  }

  Future<void> requestPhonePermissions() async {
    try {
      await platform.invokeMethod('requestPhonePermissions');
      await checkPhonePermissions();
    } catch (e) {
      debugPrint("Request phone permissions error: $e");
    }
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    notifyListeners();
    try {
      await platform.invokeMethod('toggleMute', {'mute': _isMuted});
    } catch (e) {
      debugPrint("Toggle mute failed: $e");
    }
  }

  Future<void> requestDefaultDialer() async {
    try {
      await platform.invokeMethod('requestDefaultDialer');
      // Wait a bit, then recheck
      Future.delayed(const Duration(seconds: 3), () => checkPhonePermissions());
    } catch (e) {
      debugPrint("Request default dialer failed: $e");
    }
  }
  
  void _startLocationUpdates() {
    if (!hasLocationPermission) return;
    
    _positionStreamSubscription?.cancel();
    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((Position position) {
      if (!_isDemoMode) {
        _speed = position.speed;
        if (_speed < 0) _speed = 0;
        _altitude = position.altitude;
        _heading = position.heading;
        notifyListeners();
        
        if (_lastSpeedLimitPosition == null || 
            Geolocator.distanceBetween(_lastSpeedLimitPosition!.latitude, _lastSpeedLimitPosition!.longitude, position.latitude, position.longitude) > 200) {
            _lastSpeedLimitPosition = position;
            _fetchSpeedLimit(position);
            _fetchStreetName(position);
        }
      }
    });
  }
  
  void _startDashcamPolling() {
    Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final isRecording = await platform.invokeMethod<bool>('getDashcamStatus');
        if (isRecording != null && isRecording != _dashcamRecording) {
           _dashcamRecording = isRecording;
           notifyListeners();
        }
      } catch (e) {
        // Ignored
      }
    });
  }
  
  Future<void> _fetchStreetName(Position position) async {
     try {
        final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=${position.latitude}&lon=${position.longitude}&zoom=18&addressdetails=1');
        final response = await http.get(url, headers: {'User-Agent': 'CarDashboardApp/1.0'}).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
           final data = jsonDecode(response.body);
           if (data['address'] != null) {
              final road = data['address']['road'] ?? data['address']['residential'] ?? data['address']['street'] ?? '';
              if (road.isNotEmpty) {
                 _streetName = road;
                 notifyListeners();
              }
           }
        }
     } catch (e) {
        // Ignored
     }
  }

  Future<void> _fetchSpeedLimit(Position position) async {
     try {
        final lat = position.latitude;
        final lon = position.longitude;
        final query = '[out:json];way(around:30,$lat,$lon)["maxspeed"]["highway"!="service"];out tags;';
        final url = Uri.parse('https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}');
        
        final response = await http.get(url, headers: {'User-Agent': 'CarDashboardApp/1.0'}).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
           final data = jsonDecode(response.body);
           if (data['elements'] != null && data['elements'].isNotEmpty) {
               final String ms = data['elements'][0]['tags']['maxspeed'] ?? '';
               // Extract just the numbers in case it says "80 mph"
               final match = RegExp(r'\d+').firstMatch(ms);
               if (match != null) {
                   _speedLimit = match.group(0)!;
                   notifyListeners();
               }
           } else {
               if (_speedLimit != '?') {
                  _speedLimit = '?';
                  notifyListeners();
               }
           }
        }
     } catch (e) {
        debugPrint("Speed limit fetch failed: $e");
     }
  }

  Future<void> checkPermissions() async {
    try {
      final result = await platform.invokeMethod<bool>('checkOverlay');
      _canDrawOverlays = result ?? false;
      
      final notifResult = await platform.invokeMethod<bool>('checkNotificationAccess');
      _hasNotificationAccess = notifResult ?? false;
      
      notifyListeners();
    } catch (e) {
      debugPrint("Permissions check failed: $e");
    }
  }
  
  Future<void> requestNotificationAccess() async {
    try {
      await platform.invokeMethod('requestNotificationAccess');
      Future.delayed(const Duration(seconds: 4), () => checkPermissions());
    } catch (e) {
      debugPrint("Request notif failed: $e");
    }
  }

  Future<void> requestOverlayPermission() async {
    try {
      await platform.invokeMethod('requestOverlay');
      // Wait a bit and check again
      Future.delayed(const Duration(seconds: 3), () => checkPermissions());
    } catch (e) {
      debugPrint("Request overlay failed: $e");
    }
  }

  void setWaitingForMusic() {
    _waitingForMusicToReturn = true;
  }

  static const platform = MethodChannel('com.example.car_dashboard/system');

  void _triggerReturn() async {
    try {
      debugPrint("TRIGGERING NATIVE BRING TO FRONT");
      await platform.invokeMethod('bringToFront');
      debugPrint("NATIVE BRING TO FRONT EXECUTED");
    } catch (e) {
      debugPrint("Return-to-foreground failed: $e");
    }
  }

  void _startMediaPolling() {
    _mediaTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_isDemoMode) return;
      try {
        final dynamic mediaInfo = await FlutterMediaController.getCurrentMediaInfo();
        if (mediaInfo != null) {
           final title = mediaInfo.track?.toString() ?? '';
           final artist = mediaInfo.artist?.toString() ?? '';
           final isCurrentlyPlaying = mediaInfo.isPlaying == true;
           
           if (_waitingForMusicToReturn && isCurrentlyPlaying) {
              _waitingForMusicToReturn = false;
              _triggerReturn();
           }
           
           if (title != _currentTrack || artist != _currentArtist || _isPlaying != isCurrentlyPlaying) {
              if (title.isNotEmpty) _currentTrack = title;
              if (artist.isNotEmpty) _currentArtist = artist;
              
              if (!_isPlaying && isCurrentlyPlaying) {
                 // Music started playing
                 if (!_userManuallySwitchedTab) {
                    _selectedSidebarTab = 1; // Switch to phone tab automatically
                 }
              }
              _isPlaying = isCurrentlyPlaying;
              notifyListeners();
              
              if (title.isNotEmpty && title != 'Not Playing') {
                 await _fetchNativeAlbumArt();
              } else {
                 _currentAlbumArtBytes = null;
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
    });
  }

  @override
  void dispose() {
    _mediaTimer?.cancel();
    _positionStreamSubscription?.cancel();
    _demoTimer?.cancel();
    super.dispose();
  }

  Future<void> checkLocationSettingsAndPermissions() async {
    try {
      _serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!_serviceEnabled) {
        _errorMessage = "GPS is disabled. Please enable location services.";
        notifyListeners();
        return;
      }

      _permission = await Geolocator.checkPermission();
      if (_permission == LocationPermission.denied) {
        _permission = await Geolocator.requestPermission();
        if (_permission == LocationPermission.denied) {
          _errorMessage = "Location permissions are denied.";
          notifyListeners();
          return;
        }
      }

      if (_permission == LocationPermission.deniedForever) {
        _errorMessage = "GPS permissions are permanently denied.";
        notifyListeners();
        return;
      }

      _errorMessage = '';
    } catch (e) {
      _errorMessage = "Failed to initialize GPS: $e";
    }
    notifyListeners();
  }

  Future<void> loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final titles = prefs.getStringList('fav_titles');
    final urls = prefs.getStringList('fav_urls');
    final subtitles = prefs.getStringList('fav_subtitles');
    
    if (titles != null && urls != null && titles.length == urls.length && titles.isNotEmpty) {
      _favorites = List.generate(titles.length, (i) => {
        'title': titles[i],
        'url': urls[i],
        'subtitle': (subtitles != null && i < subtitles.length) ? subtitles[i] : 'YouTube Music Playlist',
      });
      notifyListeners();
    }
  }

  Future<void> saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('fav_titles', _favorites.map((e) => e['title'] ?? '').toList());
    await prefs.setStringList('fav_urls', _favorites.map((e) => e['url'] ?? '').toList());
    await prefs.setStringList('fav_subtitles', _favorites.map((e) => e['subtitle'] ?? 'YouTube Music Playlist').toList());
    notifyListeners();
  }

  void updateFavorites(List<Map<String, String>> newFavorites) {
    _favorites = newFavorites;
    saveFavorites();
  }

          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: onSurface.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: onSurface.withOpacity(0.05)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: onSurface.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.icon,
                    color: onSurface.withOpacity(0.7),
                    size: 16,
                  ),
                ),
                const SizedBox(width: 10),
                
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: TextStyle(
                          color: onSurface,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          color: onSurface.withOpacity(0.7),
                          fontSize: 9,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                
                Icon(
                  Icons.play_circle_outline,
                  color: onSurface.withOpacity(0.8),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AutoScrollText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const AutoScrollText({super.key, required this.text, required this.style});

  @override
  State<AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<AutoScrollText> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _startScrolling();
  }

  @override
  void didUpdateWidget(AutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _scrollController.jumpTo(0);
      _startScrolling();
    }
  }

  void _startScrolling() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), _scroll);
  }

  void _scroll() {
    if (!mounted || !_scrollController.hasClients) return;
    
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll > 0) {
      final duration = Duration(milliseconds: (maxScroll * 20).toInt());
      _scrollController.animateTo(
        maxScroll,
        duration: duration,
        curve: Curves.linear,
      ).then((_) {
        if (!mounted) return;
        _timer = Timer(const Duration(seconds: 2), () {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.jumpTo(0);
          _startScrolling();
        });
      });
    } else {
      _timer = Timer(const Duration(seconds: 2), _scroll);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
      ),
    );
  }
}
