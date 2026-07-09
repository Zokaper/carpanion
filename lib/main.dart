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
import 'ui/settings_screen.dart';
import 'ui/sidebar_tabs.dart';
import 'ui/phone_tab.dart';
import 'ui/welcome_overlay.dart';
import 'package:share_handler/share_handler.dart';
import 'services/youtube_service.dart';
import 'services/collab_service.dart';
import 'dart:math' as math;
import 'ui/queue_tab.dart';
import 'ui/ytmusic_login_webview.dart';

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
        ChangeNotifierProvider(create: (_) => YouTubeService()),
        // Collab engine — lives app-wide so it survives navigation and persists
        // across restarts. Reads the two providers above (declared earlier).
        ChangeNotifierProvider(
          create: (context) => CollabService(
            context.read<DashboardProvider>(),
            context.read<YouTubeService>(),
          ),
        ),
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

  bool _showWelcomeUI = false;
  bool get showWelcomeUI => _showWelcomeUI;

  void dismissWelcomeUI() {
    _showWelcomeUI = false;
    updateLastActiveTime();
    notifyListeners();
  }

  void forceShowWelcomeUI() {
    _showWelcomeUI = true;
    notifyListeners();
  }

  // Fullscreen Settings page (rendered as a top-level Stack layer, like the
  // welcome overlay) instead of a floating dialog.
  bool _showSettingsUI = false;
  bool get showSettingsUI => _showSettingsUI;

  void forceShowSettingsUI() {
    _showSettingsUI = true;
    notifyListeners();
  }

  void dismissSettingsUI() {
    _showSettingsUI = false;
    notifyListeners();
  }

  Future<void> updateLastActiveTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lastActiveTime', DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> checkNewDrive() async {
    if (!_featWelcomeOverlay) {
      _showWelcomeUI = false;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final lastTime = prefs.getInt('lastActiveTime');
    bool shouldShow = false;

    if (lastTime != null) {
      final lastActiveDate = DateTime.fromMillisecondsSinceEpoch(lastTime);
      final diff = DateTime.now().difference(lastActiveDate);
      if (diff.inMinutes >= 10) {
        bool isNavigating = false;
        try {
          isNavigating = await platform.invokeMethod<bool>('isNavigating') ?? false;
        } catch (e) {}

        if (!_isPlaying && !isNavigating && _speed < 1.39) {
          shouldShow = true;
        }
      }
    } else {
      shouldShow = true;
    }

    _showWelcomeUI = shouldShow;
    if (!shouldShow) {
      updateLastActiveTime();
    }
    notifyListeners();
  }

  // Favorites state variables. Only song/album/artist now — playlists/mixes live
  // in the home-feed grid on the favorites screen (V4).
  List<Map<String, String>> _favorites = [];

  List<Map<String, String>> get favorites => _favorites;

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
  double _accuracy = 0.0;
  double _altitude = 0.0;
  double _heading = 0.0;
  String _streetName = 'Scanning...';

  double _mediaPosition = 0.0;
  double _mediaDuration = 1.0;
  Uint8List? _currentAlbumArtBytes;

  bool get isKmph => _isKmph;
  double get speed => _speed;
  double get accuracy => _accuracy;
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

  bool _isWifi = false;
  int _wifiBars = 0;
  bool _isCellular = false;
  int _cellularBars = 0;

  bool get isWifi => _isWifi;
  int get wifiBars => _wifiBars;
  bool get isCellular => _isCellular;
  int get cellularBars => _cellularBars;

  int _ringerMode = 2; // 0=Silent, 1=Vibrate, 2=Normal
  int get ringerMode => _ringerMode;

  Future<void> toggleRingerMode() async {
    int newMode = (_ringerMode + 1) % 3;
    try {
      final success = await platform.invokeMethod<bool>('setRingerMode', {'mode': newMode});
      if (success == true) {
        _ringerMode = newMode;
        _lastSystemControlWrite = DateTime.now();
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Failed to set ringer mode: $e");
    }
  }

  int _brightness = 128; // 0-255
  bool _isAdaptiveBrightness = true;

  int get brightness => _brightness;
  bool get isAdaptiveBrightness => _isAdaptiveBrightness;

  // When the user just changed brightness/ringer, suppress the 3s poll from
  // overwriting those fields with a stale native read (which would visibly snap
  // the slider/toggle back).
  DateTime? _lastSystemControlWrite;
  bool get _systemControlRecentlySet =>
      _lastSystemControlWrite != null &&
      DateTime.now().difference(_lastSystemControlWrite!) < const Duration(seconds: 4);

  Future<void> setBrightness(int value) async {
    _brightness = value;
    _lastSystemControlWrite = DateTime.now();
    notifyListeners();
    try {
      await platform.invokeMethod('setSystemBrightness', {'brightness': value});
    } catch (e) {
      debugPrint("Failed to set brightness: $e");
    }
  }

  Future<void> toggleAdaptiveBrightness() async {
    _isAdaptiveBrightness = !_isAdaptiveBrightness;
    _lastSystemControlWrite = DateTime.now();
    notifyListeners();
    _persistBool(_kFeatAdaptiveBrightness, _isAdaptiveBrightness);
    try {
      await platform.invokeMethod('setSystemBrightness', {'adaptive': _isAdaptiveBrightness});
    } catch (e) {
      debugPrint("Failed to toggle adaptive brightness: $e");
    }
  }
  
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

  // ── Feature flags (persisted) ───────────────────────────────────────────
  // Each gates an optional feature so the user can turn it off in Settings.
  // Defaults preserve prod behavior. Setters persist → notify → start/stop
  // the underlying work. A feature stays ON but dormant if its required
  // permission is missing (consumers check `flag && permissionGranted`).
  bool _featSpeedLimit = true;
  bool _featSpeedWarning = true;
  bool _featDashcam = true;
  bool _featWelcomeOverlay = true;
  bool _featMapsAutolaunch = true;
  bool _featNotifications = true;
  bool _featShareFavorites = true;
  int _phoneMode = 1; // 0=Off, 1=In-app only, 2=Full (default dialer)

  bool get featSpeedLimit => _featSpeedLimit;
  bool get featSpeedWarning => _featSpeedWarning;
  bool get featDashcam => _featDashcam;
  bool get featWelcomeOverlay => _featWelcomeOverlay;
  bool get featMapsAutolaunch => _featMapsAutolaunch;
  bool get featNotifications => _featNotifications;
  bool get featShareFavorites => _featShareFavorites;
  int get phoneMode => _phoneMode;

  static const String _kFeatSpeedLimit = 'feat_speed_limit';
  static const String _kFeatSpeedWarning = 'feat_speed_warning';
  static const String _kFeatDashcam = 'feat_dashcam';
  static const String _kFeatWelcomeOverlay = 'feat_welcome_overlay';
  static const String _kFeatMapsAutolaunch = 'feat_maps_autolaunch';
  static const String _kFeatNotifications = 'feat_notifications';
  static const String _kFeatShareFavorites = 'feat_share_favorites';
  static const String _kFeatAdaptiveBrightness = 'feat_adaptive_brightness';
  static const String _kPhoneMode = 'phone_mode';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _featSpeedLimit = prefs.getBool(_kFeatSpeedLimit) ?? true;
    _featSpeedWarning = prefs.getBool(_kFeatSpeedWarning) ?? true;
    _featDashcam = prefs.getBool(_kFeatDashcam) ?? true;
    _featWelcomeOverlay = prefs.getBool(_kFeatWelcomeOverlay) ?? true;
    _featMapsAutolaunch = prefs.getBool(_kFeatMapsAutolaunch) ?? true;
    _featNotifications = prefs.getBool(_kFeatNotifications) ?? true;
    _featShareFavorites = prefs.getBool(_kFeatShareFavorites) ?? true;
    _isAdaptiveBrightness =
        prefs.getBool(_kFeatAdaptiveBrightness) ?? _isAdaptiveBrightness;
    _phoneMode = prefs.getInt(_kPhoneMode) ?? 1;
  }

  Future<void> _persistBool(String key, bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, v);
  }

  Future<void> setFeatSpeedLimit(bool v) async {
    if (_featSpeedLimit == v) return;
    _featSpeedLimit = v;
    notifyListeners();
    await _persistBool(_kFeatSpeedLimit, v);
  }

  Future<void> setFeatSpeedWarning(bool v) async {
    if (_featSpeedWarning == v) return;
    _featSpeedWarning = v;
    notifyListeners();
    await _persistBool(_kFeatSpeedWarning, v);
  }

  Future<void> setFeatDashcam(bool v) async {
    if (_featDashcam == v) return;
    _featDashcam = v;
    notifyListeners();
    if (v) {
      _startDashcamPolling();
    } else {
      stopDashcamPolling();
    }
    await _persistBool(_kFeatDashcam, v);
  }

  Future<void> setFeatWelcomeOverlay(bool v) async {
    if (_featWelcomeOverlay == v) return;
    _featWelcomeOverlay = v;
    if (!v) _showWelcomeUI = false;
    notifyListeners();
    await _persistBool(_kFeatWelcomeOverlay, v);
  }

  Future<void> setFeatMapsAutolaunch(bool v) async {
    if (_featMapsAutolaunch == v) return;
    _featMapsAutolaunch = v;
    notifyListeners();
    await _persistBool(_kFeatMapsAutolaunch, v);
  }

  Future<void> setFeatNotifications(bool v) async {
    if (_featNotifications == v) return;
    _featNotifications = v;
    notifyListeners();
    await _persistBool(_kFeatNotifications, v);
  }

  Future<void> setFeatShareFavorites(bool v) async {
    if (_featShareFavorites == v) return;
    _featShareFavorites = v;
    notifyListeners();
    if (v) {
      initShareHandler();
    } else {
      _shareSubscription?.cancel();
      _shareSubscription = null;
    }
    await _persistBool(_kFeatShareFavorites, v);
  }

  Future<void> setPhoneMode(int mode) async {
    if (_phoneMode == mode) return;
    _phoneMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPhoneMode, mode);
  }

  Timer? _mediaTimer;
  Timer? _dashcamTimer;
  Timer? _networkTimer;

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
          if (timer.tick <= 30) {
            // First 3 seconds: accelerate from 0 to 125 km/h
            _speed += (125.0 / 3.6) / 30.0;
          } else {
            // Fluctuate speed smoothly using a sine wave around 125 km/h
            double wave = math.sin((timer.tick - 30) * 0.05);
            double speedKmph = 125.0 + (wave * 10.0);
            _speed = speedKmph / 3.6; // convert to m/s
          }
          
          _speedLimit = "120"; // Force 120 limit
          _accuracy = 4.5;
          _altitude = 650.0 + _speed;
          _heading = (_heading + 1.5) % 360;
          _streetName = "King Fahd Road";
          notifyListeners();
       });
       _errorMessage = '';
    } else {
       _demoTimer?.cancel();
       _speed = 0.0;
       _speedLimit = '?';
       _streetName = 'Scanning...';
       _accuracy = 0.0;
       checkLocationSettingsAndPermissions();
    }
    notifyListeners();
  }

  void setPlaying(bool state) {
    _isPlaying = state;
    notifyListeners();
  }

  /// Seeks YT Music's MediaSession to [ms] (milliseconds). Optimistically updates
  /// the local position so the progress bar doesn't jump back before the next poll.
  Future<void> seekTo(int ms) async {
    _mediaPosition = ms.toDouble();
    notifyListeners();
    try {
      await platform.invokeMethod('seekTo', {'position': ms});
    } catch (e) {
      debugPrint("Seek failed: $e");
    }
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
    await _loadSettings();
    await checkNewDrive();
    checkPermissions();
    await checkLocationSettingsAndPermissions();
    _startLocationUpdates();
    _startMediaPolling();
    if (_featDashcam) _startDashcamPolling();
    _startNetworkPolling();

    await loadFavorites();
    if (_featShareFavorites) initShareHandler();

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
    // Phone handling disabled → never surface the in-app call UI.
    if (_phoneMode == 0) {
      if (_callState != 'IDLE') {
        _callState = 'IDLE';
        _callNumber = '';
        _callName = '';
        _callDurationSeconds = 0;
        _callDurationTimer?.cancel();
        _callDurationTimer = null;
        _callStartTime = null;
        notifyListeners();
      }
      return;
    }
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
        final resolved = await _resolveContactName(_callNumber);
        // A newer call-state event (e.g. the call ended) may have run fully during
        // the await above — don't clobber it with this now-stale resolution.
        if (_callState != stateStr || _callNumber != number) return;
        _callName = resolved;
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

  List<Contact>? _cachedContacts;

  Future<String> _resolveContactName(String number) async {
    try {
      final cleanNumber = number.replaceAll(RegExp(r'\D'), '');
      if (cleanNumber.isEmpty) return 'Unknown Caller';
      
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      if (status != PermissionStatus.granted) {
        return number.isNotEmpty ? number : 'Unknown Caller';
      }
      
      if (_cachedContacts == null) {
        _cachedContacts = await FlutterContacts.getAll(properties: ContactProperties.allProperties);
      }
      
      for (final contact in _cachedContacts!) {
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
        _accuracy = position.accuracy;
        if (_speed < 0) _speed = 0;
        _altitude = position.altitude;
        _heading = position.heading;
        notifyListeners();
        
        if (_lastSpeedLimitPosition == null ||
            Geolocator.distanceBetween(_lastSpeedLimitPosition!.latitude, _lastSpeedLimitPosition!.longitude, position.latitude, position.longitude) > 200) {
            // Only advance the anchor once we actually kick off a fetch; if one is
            // already in flight, leave the anchor so the next position retries
            // instead of being silently skipped for another 200 m.
            if (!_isFetchingSpeedLimit) {
              _lastSpeedLimitPosition = position;
              if (_featSpeedLimit) _fetchSpeedLimit(position);
              _fetchStreetName(position);
            }
        }
      }
    });
  }
  
  bool _isFetchingDashcam = false;
  
  void _startDashcamPolling() {
    _dashcamTimer?.cancel();
    _dashcamTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_isFetchingDashcam) return;
      _isFetchingDashcam = true;
      try {
        final isRecording = await platform.invokeMethod<bool>('getDashcamStatus');
        if (isRecording != null && isRecording != _dashcamRecording) {
           _dashcamRecording = isRecording;
           notifyListeners();
        }
      } catch (e) {
        debugPrint("Dashcam polling error: $e");
      } finally {
        _isFetchingDashcam = false;
      }
    });
  }
  
  void stopDashcamPolling() {
    _dashcamTimer?.cancel();
    _dashcamTimer = null;
    if (_dashcamRecording) {
      _dashcamRecording = false;
      notifyListeners();
    }
  }

  Future<void> stopDashcam() async {
    try {
      await platform.invokeMethod('stopDashcam');
      _dashcamRecording = false;
      notifyListeners();
    } catch (e) {
      debugPrint("Stop dashcam failed: $e");
    }
  }

  bool _isFetchingNetwork = false;

  void _startNetworkPolling() {
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_isDemoMode) {
        if (!_isWifi || _wifiBars != 4 || !_isCellular || _cellularBars != 4) {
          _isWifi = true;
          _wifiBars = 4;
          _isCellular = true;
          _cellularBars = 4;
          notifyListeners();
        }
        return;
      }
      if (_isFetchingNetwork) return;
      _isFetchingNetwork = true;
      try {
        final Map<dynamic, dynamic>? status = await platform.invokeMethod('getNetworkStatus');
        if (status != null) {
          bool changed = false;
          final bool w = status['isWifi'] ?? false;
          final int wb = status['wifiBars'] ?? 0;
          final bool c = status['isCellular'] ?? false;
          final int cb = status['cellularBars'] ?? 0;

          if (_isWifi != w || _wifiBars != wb || _isCellular != c || _cellularBars != cb) {
            _isWifi = w;
            _wifiBars = wb;
            _isCellular = c;
            _cellularBars = cb;
            changed = true;
          }

          // Skip overwriting ringer/brightness right after the user set them, so
          // a stale native read doesn't snap the control back.
          if (!_systemControlRecentlySet) {
            final int? rMode = await platform.invokeMethod<int>('getRingerMode');
            if (rMode != null && rMode != _ringerMode) {
              _ringerMode = rMode;
              changed = true;
            }

            final Map<dynamic, dynamic>? bInfo = await platform.invokeMethod('getBrightnessInfo');
            if (bInfo != null) {
              final int b = bInfo['brightness'] as int? ?? 128;
              final bool a = bInfo['adaptive'] as bool? ?? true;
              if (_brightness != b || _isAdaptiveBrightness != a) {
                _brightness = b;
                _isAdaptiveBrightness = a;
                changed = true;
              }
            }
          }

          if (changed) notifyListeners();
        }
      } catch (e) {
        debugPrint("Network polling error: $e");
      } finally {
        _isFetchingNetwork = false;
      }
    });
  }

  bool _isFetchingStreetName = false;

  Future<void> _fetchStreetName(Position position) async {
     if (_isFetchingStreetName) return;
     _isFetchingStreetName = true;
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
        debugPrint("Street name fetch error: $e");
     } finally {
        _isFetchingStreetName = false;
     }
  }

  bool _isFetchingSpeedLimit = false;

  Future<void> _fetchSpeedLimit(Position position) async {
     if (_isFetchingSpeedLimit) return;
     _isFetchingSpeedLimit = true;
     try {
        final lat = position.latitude;
        final lon = position.longitude;
        final query = '[out:json];way(around:10,$lat,$lon)["maxspeed"]["highway"!="service"];out tags;';
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
     } finally {
        _isFetchingSpeedLimit = false;
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

  bool _isFetchingMedia = false;

  void _startMediaPolling() {
    _mediaTimer?.cancel();
    _mediaTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_isDemoMode) return;
      // A tick can outlast its 1s interval (album-art fetch); don't let the next
      // tick run concurrently and clobber the now-playing state.
      if (_isFetchingMedia) return;
      _isFetchingMedia = true;
      bool changed = false;
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

              // Pull the album name from the MediaSession metadata (not exposed by
              // the plugin) so albums can be favorited.
              try {
                final meta = await platform.invokeMethod('getCurrentMediaMetadata');
                if (meta is Map && meta['album'] != null) {
                  _currentAlbum = meta['album'].toString();
                }
              } catch (_) {}

              _isPlaying = isCurrentlyPlaying;
              changed = true;

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
           final pos = (progress['position'] as num?)?.toDouble() ?? _mediaPosition;
           double dur = (progress['duration'] as num?)?.toDouble() ?? _mediaDuration;
           if (dur <= 0) dur = 1.0; // Prevent divide by zero
           if (pos != _mediaPosition || dur != _mediaDuration) {
              _mediaPosition = pos;
              _mediaDuration = dur;
              changed = true;
           }
        }

        if (changed) notifyListeners();
      } catch (e) {
        debugPrint("Media polling error: $e");
      } finally {
        _isFetchingMedia = false;
      }
    });
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    // Async callbacks that resolve after this provider is disposed must not
    // touch listeners (would throw "used after being disposed").
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _mediaTimer?.cancel();
    _dashcamTimer?.cancel();
    _networkTimer?.cancel();
    _callDurationTimer?.cancel();
    _positionStreamSubscription?.cancel();
    _demoTimer?.cancel();
    _shareSubscription?.cancel();
    platform.setMethodCallHandler(null);
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
    // New typed format: a single JSON list.
    final json = prefs.getString('fav_json');
    if (json != null && json.isNotEmpty) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is List) {
          final all = decoded
              .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
              .toList();
          // V4: playlist/mix favorites moved to the home-feed grid — strip any
          // lingering ones so the list is song/album/artist only.
          _favorites = all.where((f) => (f['type'] ?? 'playlist') != 'playlist').toList();
          if (_favorites.length != all.length) await saveFavorites();
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('Failed to parse fav_json: $e');
      }
    }
    // Migrate the old parallel-list format (all treated as legacy playlists).
    final titles = prefs.getStringList('fav_titles');
    final urls = prefs.getStringList('fav_urls');
    final subtitles = prefs.getStringList('fav_subtitles');
    if (titles != null && urls != null && titles.length == urls.length && titles.isNotEmpty) {
      _favorites = List.generate(titles.length, (i) => {
        'type': 'playlist',
        'title': titles[i],
        'url': urls[i],
        'subtitle': (subtitles != null && i < subtitles.length) ? subtitles[i] : 'YouTube Music Playlist',
      });
      await saveFavorites(); // re-persist in the new format
      notifyListeners();
    }
  }

  Future<void> saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fav_json', jsonEncode(_favorites));
    notifyListeners();
  }

  void updateFavorites(List<Map<String, String>> newFavorites) {
    _favorites = newFavorites;
    saveFavorites();
  }

  void addNewFavorite(Map<String, String> newFav) {
    // No cap — favorites list scrolls and is type-filterable, so add freely.
    _favorites.insert(0, newFav);
    saveFavorites();
    setSidebarTab(0); // Switch to Media tab
    notifyListeners();
  }

  void removeFavoriteAt(int index) {
    if (index >= 0 && index < _favorites.length) {
      _favorites.removeAt(index);
      saveFavorites();
      notifyListeners();
    }
  }

  void removeFavoriteByTitle(String title) {
    _favorites.removeWhere((fav) => fav['title'] == title);
    saveFavorites();
    notifyListeners();
  }

  // --- Typed favorites (song / album / artist) ---
  bool isSongFavorited(String title) => _favorites.any((f) => f['type'] == 'song' && f['title'] == title);
  bool isAlbumFavorited(String album) => _favorites.any((f) => f['type'] == 'album' && f['title'] == album);
  bool isArtistFavorited(String artist) => _favorites.any((f) => f['type'] == 'artist' && f['title'] == artist);

  void removeFavoriteTyped(String title, String type) {
    _favorites.removeWhere((f) => f['type'] == type && f['title'] == title);
    saveFavorites();
    notifyListeners();
  }

  /// Adds a song favorite (videoId + thumbnail already resolved by the caller so
  /// it plays instantly later). Falls back to the '$title $artist' query if the
  /// videoId is empty.
  void addSongFavorite({required String title, required String artist, required String videoId, required String thumbnail}) {
    addNewFavorite({
      'type': 'song',
      'title': title,
      'subtitle': artist,
      'videoId': videoId,
      'thumbnail': thumbnail,
      'url': '$title $artist',
    });
  }

  void toggleAlbumFavorite(String album, String artist) {
    if (isAlbumFavorited(album)) {
      removeFavoriteTyped(album, 'album');
    } else {
      addNewFavorite({'type': 'album', 'title': album, 'subtitle': artist, 'url': '$album $artist'});
    }
  }

  void toggleArtistFavorite(String artist) {
    if (isArtistFavorited(artist)) {
      removeFavoriteTyped(artist, 'artist');
    } else {
      addNewFavorite({'type': 'artist', 'title': artist, 'subtitle': 'Artist', 'url': artist});
    }
  }

  void handleSharedText(String sharedText) async {
    String title = sharedText;
    String url = sharedText;
    String subtitle = 'Search Query';
    
    if (sharedText.contains('\n')) {
      final parts = sharedText.split('\n');
      title = parts[0].trim();
      if (parts.length > 1) {
        url = parts[1].trim();
      }
    } else if (sharedText.startsWith('http')) {
      url = sharedText;
      title = "Loading...";
      subtitle = 'Shared Link';
      try {
         final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 3));
         if (response.statusCode == 200) {
            final match = RegExp(r'<title>(.*?)</title>').firstMatch(response.body);
            if (match != null) {
               String fetchedTitle = match.group(1) ?? "Shared Link";
               fetchedTitle = fetchedTitle.replaceAll('- YouTube Music', '').replaceAll('- YouTube', '').trim();
               fetchedTitle = fetchedTitle.replaceAll('&#39;', "'").replaceAll('&quot;', '"').replaceAll('&amp;', '&');
               
               String finalTitle = fetchedTitle;
               String finalSubtitle = "YouTube Music";

               if (fetchedTitle.contains(' - ')) {
                 final split = fetchedTitle.split(' - ');
                 finalTitle = split[0].trim();
                 finalSubtitle = split.sublist(1).join(' - ').trim();
               }

               if (finalTitle.isNotEmpty && finalTitle != "YouTube") {
                 // Update asynchronously
                 for (int i = 0; i < _favorites.length; i++) {
                   if (_favorites[i]['url'] == url && _favorites[i]['title'] == "Loading...") {
                     _favorites[i]['title'] = finalTitle.length > 40 ? "${finalTitle.substring(0, 37)}..." : finalTitle;
                     _favorites[i]['subtitle'] = finalSubtitle;
                     saveFavorites();
                     notifyListeners();
                     break;
                   }
                 }
                 return; // Avoid doing it synchronously below
               }
            }
         }
      } catch (e) {
         debugPrint("Failed to fetch title for URL: $e");
         for (int i = 0; i < _favorites.length; i++) {
           if (_favorites[i]['url'] == url && _favorites[i]['title'] == "Loading...") {
             _favorites[i]['title'] = "Shared Link";
             saveFavorites();
             notifyListeners();
             break;
           }
         }
      }
    }

    // Limit length if necessary
    if (title.length > 40) title = "${title.substring(0, 37)}...";

    final newFav = {'title': title, 'url': url, 'subtitle': subtitle};
    addNewFavorite(newFav);
  }

  StreamSubscription<SharedMedia>? _shareSubscription;

  void initShareHandler() async {
    final handler = ShareHandlerPlatform.instance;
    try {
      final initialMedia = await handler.getInitialSharedMedia();
      if (initialMedia != null && initialMedia.content != null) {
        handleSharedText(initialMedia.content!);
      }
    } catch (e) {
      debugPrint("Initial share error: $e");
    }

    _shareSubscription = handler.sharedMediaStream.listen((SharedMedia media) {
      if (media.content != null) {
        handleSharedText(media.content!);
      }
    });
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Provider.of<DashboardProvider>(context, listen: false).checkPermissions();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      Provider.of<DashboardProvider>(context, listen: false).updateLastActiveTime();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context, listen: false);

    return Scaffold(
      body: Stack(
        children: [
          // Immersive in-car UI hides the system bars (see main()), so don't reserve
          // their insets — draw edge-to-edge to fill the whole display.
          SafeArea(
        left: false,
        top: false,
        right: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
          child: Column(
            children: [
              // Top Header Bar
              const HeaderBarWidget(),
              const SizedBox(height: 10),
              
              // Warning banner if permissions/services are missing
              Consumer<DashboardProvider>(
                builder: (context, prov, child) {
                  if (prov.errorMessage.isNotEmpty && !prov.isDemoMode) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3D00).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFF3D00).withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF3D00), size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              prov.errorMessage,
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ),
                          TextButton(
                            onPressed: prov.checkLocationSettingsAndPermissions,
                            child: const Text("RETRY", style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: prov.toggleDemoMode,
                            child: const Text("USE DEMO MODE", style: TextStyle(color: Colors.white70)),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),

              // Main columns: Speed (7), Media Controls (8), Favorites Sidebar (6)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Left Column: Speedometer
                    const Expanded(
                      flex: 7,
                      child: SpeedometerWidget(),
                    ),
                    const SizedBox(width: 14),
                    
                    // Center Column: Media Control Panel or Call Screen
                    Expanded(
                      flex: 8,
                      child: Consumer<DashboardProvider>(
                        builder: (context, prov, child) {
                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            transitionBuilder: (Widget child, Animation<double> animation) {
                              return FadeTransition(opacity: animation, child: child);
                            },
                            child: prov.callState != 'IDLE' 
                                ? const CallScreenWidget(key: ValueKey('call_screen')) 
                                : const MediaControlPanel(key: ValueKey('media_panel')),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 14),
                    
                    // Right Column: Tab Content
                    const Expanded(
                      flex: 6,
                      child: SidebarContentWidget(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
          Consumer<DashboardProvider>(
            builder: (context, prov, child) {
              if (prov.showWelcomeUI) {
                return const WelcomeOverlayWidget();
              }
              return const SizedBox.shrink();
            },
          ),
          Consumer<DashboardProvider>(
            builder: (context, prov, child) {
              if (prov.showSettingsUI) {
                return const SettingsScreen();
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// CLOCK WIDGET
// ----------------------------------------------------------------------------
class ClockWidget extends StatefulWidget {
  final Color color;
  const ClockWidget({super.key, required this.color});

  @override
  State<ClockWidget> createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<ClockWidget> {
  late Stream<DateTime> _clockStream;

  @override
  void initState() {
    super.initState();
    _clockStream = Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()).asBroadcastStream();
  }

  String _getMonthName(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }

  String _getWeekdayName(int day) {
    const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
    return days[day % 7];
  }

  String _formatTime(DateTime time) {
    final hour = time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
    final amPm = time.hour >= 12 ? "PM" : "AM";
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return "$hour:$minute:$second $amPm";
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DateTime>(
      stream: _clockStream,
      initialData: DateTime.now(),
      builder: (context, snapshot) {
        final now = snapshot.data ?? DateTime.now();
        return Row(
          children: [
            Text(
              _formatTime(now),
              style: TextStyle(
                color: widget.color,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 10),
            Container(width: 1, height: 12, color: widget.color.withOpacity(0.24)),
            const SizedBox(width: 10),
            Text(
              "${_getWeekdayName(now.weekday)}, ${_getMonthName(now.month)} ${now.day}",
              style: TextStyle(
                color: widget.color.withOpacity(0.6),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ----------------------------------------------------------------------------
// HEADER BAR WIDGET
// ----------------------------------------------------------------------------
class HeaderBarWidget extends StatelessWidget {
  const HeaderBarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final provider = Provider.of<DashboardProvider>(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: onSurface.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          // Left Column Header (Flex 7): Speed/Clock
          Expanded(
            flex: 7,
            child: Row(
              children: [
                Row(
                  children: [
                    Icon(Icons.speed, color: onSurface, size: 28),
                    const SizedBox(width: 12),
                  ],
                ),
                ClockWidget(color: onSurface),
              ],
            ),
          ),
          const SizedBox(width: 14),
          
          // Center Column Header (Flex 8): Settings
          Expanded(
            flex: 8,
            child: Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Brightness Slider
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: ThickBrightnessSlider(
                      brightness: provider.brightness,
                      isAdaptive: provider.isAdaptiveBrightness,
                      onChanged: (val) => provider.setBrightness(val),
                      onToggleAdaptive: () => provider.toggleAdaptiveBrightness(),
                      activeColor: theme.colorScheme.primary,
                      backgroundColor: onSurface.withOpacity(0.1),
                      iconColor: onSurface.withOpacity(0.8),
                    ),
                  ),
                ),
                Container(width: 1, height: 16, color: onSurface.withOpacity(0.24)),
                const SizedBox(width: 8),
                // Status Bar Icons
                GestureDetector(
                  onTap: () => provider.toggleRingerMode(),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (provider.isWifi) ...[
                          Icon(
                            provider.wifiBars == 0 ? Icons.signal_wifi_0_bar :
                            provider.wifiBars == 1 ? Icons.network_wifi_1_bar :
                            provider.wifiBars == 2 ? Icons.network_wifi_2_bar :
                            provider.wifiBars == 3 ? Icons.network_wifi_3_bar :
                            Icons.wifi, 
                            color: onSurface.withOpacity(0.8), 
                            size: 18
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (provider.isCellular || !provider.isWifi) ...[
                          if (!provider.isCellular)
                            Icon(Icons.signal_cellular_off, color: onSurface.withOpacity(0.8), size: 18)
                          else
                            CellularIconWidget(
                              bars: provider.cellularBars,
                              color: onSurface.withOpacity(0.8),
                              size: 18,
                            ),
                          const SizedBox(width: 8),
                        ],
                        Icon(
                          provider.ringerMode == 0 ? Icons.volume_off :
                          provider.ringerMode == 1 ? Icons.vibration :
                          Icons.volume_up, 
                          color: onSurface.withOpacity(0.8), 
                          size: 18
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(width: 1, height: 16, color: onSurface.withOpacity(0.24)),
                const SizedBox(width: 8),
                
                GestureDetector(
                  onTap: () {
                    Provider.of<DashboardProvider>(context, listen: false).forceShowWelcomeUI();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: onSurface.withOpacity(0.04),
                      shape: BoxShape.circle,
                      border: Border.all(color: onSurface.withOpacity(0.08)),
                    ),
                    child: Icon(Icons.drive_eta, color: onSurface.withOpacity(0.6), size: 16),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Provider.of<DashboardProvider>(context, listen: false).forceShowSettingsUI();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: onSurface.withOpacity(0.04),
                      shape: BoxShape.circle,
                      border: Border.all(color: onSurface.withOpacity(0.08)),
                    ),
                    child: Icon(Icons.settings, color: onSurface.withOpacity(0.6), size: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          
          // Right Column Header (Flex 6): Tabs
          Expanded(
            flex: 6,
            child: const HeaderTabsWidget(),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// MEDIA CONTROL PANEL WIDGET
// ----------------------------------------------------------------------------
class MediaControlPanel extends StatefulWidget {
  const MediaControlPanel({super.key});

  @override
  State<MediaControlPanel> createState() => _MediaControlPanelState();
}

class _MediaControlPanelState extends State<MediaControlPanel> {
  bool _isAlbumArtHidden = false;
  // While the user drags the progress bar, hold the drag position (ms) so the
  // thumb follows the finger and the 1s poller doesn't yank it back.
  double? _dragSeekMs;

  // Removed fake progress controller


  Future<void> _handleMediaAction(String action) async {
    try {
      if (action == 'playPause') {
        await FlutterMediaController.togglePlayPause();
      } else if (action == 'next') {
        await FlutterMediaController.nextTrack();
      } else if (action == 'previous') {
        await FlutterMediaController.previousTrack();
      }
    } catch (e) {
      debugPrint("Media action failed: $e");
    }
  }

  String _formatDuration(double totalMilliseconds) {
    if (totalMilliseconds <= 0) return "0:00";
    final duration = Duration(milliseconds: totalMilliseconds.toInt());
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final isPlaying = provider.isPlaying;
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    // Logic handled natively now

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: onSurface.withOpacity(0.05)),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [


          // Large Album Art on Top (Takes maximum space)
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: !_isAlbumArtHidden
                  ? GestureDetector(
                      key: const ValueKey('albumArt'),
                      onTap: () {
                        setState(() {
                          _isAlbumArtHidden = true;
                        });
                      },
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.maxWidth < constraints.maxHeight 
                              ? constraints.maxWidth 
                              : constraints.maxHeight;
                          return Container(
                            width: size,
                            height: size,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withOpacity(0.5), // fallback color
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: onSurface.withOpacity(0.1)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.2), // keep shadow black
                                  blurRadius: 15,
                                  offset: const Offset(0, 8),
                                )
                              ]
                            ),
                            clipBehavior: Clip.hardEdge,
                            child: Builder(builder: (context) {
                              // Prefer OUR queue cover (e.g. album art) when it matches
                              // the playing track — the native art of an audio-swapped
                              // single would otherwise show the single's cover.
                              final queueArt = context.watch<CollabService>().currentTrackArt;
                              if (queueArt != null && queueArt.isNotEmpty) {
                                return Image.network(
                                  queueArt,
                                  fit: BoxFit.cover,
                                  errorBuilder: (c, e, s) => provider.currentAlbumArtBytes != null
                                      ? Image.memory(provider.currentAlbumArtBytes!, fit: BoxFit.cover)
                                      : Icon(Icons.music_video_rounded, color: onSurface.withOpacity(0.2), size: 60),
                                );
                              }
                              return provider.currentAlbumArtBytes != null
                                  ? Image.memory(
                                      provider.currentAlbumArtBytes!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (c, e, s) => Icon(Icons.music_video_rounded, color: onSurface.withOpacity(0.2), size: 60),
                                    )
                                  : Center(
                                      child: Icon(Icons.music_video_rounded, color: onSurface.withOpacity(0.2), size: 60),
                                    );
                            }),
                          );
                        },
                      ),
                    )
                  : GestureDetector(
                      key: const ValueKey('hiddenArt'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() {
                          _isAlbumArtHidden = false;
                        });
                      },
                      child: SizedBox.expand(
                        child: Center(
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withOpacity(0.5),
                              shape: BoxShape.circle,
                              border: Border.all(color: onSurface.withOpacity(0.1)),
                            ),
                            child: Icon(Icons.music_video_rounded, color: onSurface.withOpacity(0.5), size: 32),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          
          const SizedBox(height: 12),

          // Track Info
          AutoScrollText(
             text: provider.currentTrack,
             style: TextStyle(
               color: onSurface,
               fontSize: 18,
               fontWeight: FontWeight.w900,
             ),
          ),
          const SizedBox(height: 2),
          AutoScrollText(
             text: provider.currentArtist,
             style: TextStyle(
               color: onSurface.withOpacity(0.6),
               fontSize: 14,
             ),
          ),
          
          const SizedBox(height: 2),
          
          // Real Native Progress Bar with Duration below it
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 24,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: theme.colorScheme.primary,
                    inactiveTrackColor: onSurface.withOpacity(0.1),
                    thumbColor: theme.colorScheme.primary,
                    trackHeight: 4.0,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                    overlayColor: theme.colorScheme.primary.withOpacity(0.2),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                  ),
                  child: Slider(
                    value: (_dragSeekMs ?? provider.mediaPosition).clamp(0.0, provider.mediaDuration),
                    min: 0.0,
                    max: provider.mediaDuration,
                    // Track the finger while dragging (poller doesn't fight it),
                    // commit the seek on release.
                    onChanged: (value) => setState(() => _dragSeekMs = value),
                    onChangeEnd: (value) {
                      provider.seekTo(value.toInt());
                      setState(() => _dragSeekMs = null);
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_dragSeekMs ?? provider.mediaPosition),
                      style: TextStyle(fontSize: 10, color: onSurface.withOpacity(0.6)),
                    ),
                    Text(
                      _formatDuration(provider.mediaDuration),
                      style: TextStyle(fontSize: 10, color: onSurface.withOpacity(0.6)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 8),

          // Control Buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlButton(
                icon: Icons.skip_previous_rounded,
                size: 26,
                onPressed: () {
                  // Queue-aware: steps back through OUR queue when one is playing,
                  // else falls through to YT Music's native previous.
                  context.read<CollabService>().previous();
                },
              ),

              _buildPlayPauseButton(
                isPlaying: isPlaying,
                onPressed: () {
                  provider.setPlaying(!isPlaying);
                  _handleMediaAction('playPause');
                },
              ),

              _buildControlButton(
                icon: Icons.skip_next_rounded,
                size: 26,
                onPressed: () {
                  // Queue-aware: advances OUR queue when one is playing, else falls
                  // through to YT Music's native next (autoplay takeover at the end).
                  context.read<CollabService>().next();
                },
              ),
            ],
          ),
        ],
      ),

      // "Playing from queue" badge — pinned top-left over the album art so it
      // no longer steals vertical space from the (already small) square cover.
      if (context.watch<CollabService>().playbackActive)
        Positioned(
          top: 0,
          left: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.queue_music, size: 12, color: theme.colorScheme.primary),
                const SizedBox(width: 5),
                Text(
                  "QUEUE",
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),

      Positioned(
        top: 0,
        right: 0,
        child: Builder(
          builder: (context) {
            final playing = provider.currentTrack.isNotEmpty && provider.currentTrack != 'Not Playing';
            final songFav = provider.isSongFavorited(provider.currentTrack);
            final albumFav = provider.currentAlbum.isNotEmpty && provider.isAlbumFavorited(provider.currentAlbum);
            final artistFav = provider.isArtistFavorited(provider.currentArtist);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _favIconButton(
                  icon: songFav ? Icons.favorite : Icons.favorite_border,
                  active: songFav,
                  theme: theme,
                  tooltip: 'Favorite song',
                  onPressed: playing ? () => _toggleSongFavorite(context, provider) : null,
                ),
                _favIconButton(
                  icon: Icons.album,
                  active: albumFav,
                  theme: theme,
                  tooltip: 'Favorite album',
                  onPressed: (playing && provider.currentAlbum.isNotEmpty)
                      ? () => provider.toggleAlbumFavorite(provider.currentAlbum, provider.currentArtist)
                      : null,
                ),
                _favIconButton(
                  icon: Icons.interpreter_mode,
                  active: artistFav,
                  theme: theme,
                  tooltip: 'Favorite artist',
                  onPressed: playing ? () => provider.toggleArtistFavorite(provider.currentArtist) : null,
                ),
              ],
            );
          }
        ),
      ),
        ],
      ),
    );
  }

  Widget _favIconButton({
    required IconData icon,
    required bool active,
    required ThemeData theme,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final color = onPressed == null
        ? theme.colorScheme.onSurface.withOpacity(0.25)
        : (active ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.55));
    return IconButton(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: color, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  /// Toggles the current track as a song favorite. When adding, resolves the
  /// exact YT Music song id up front so playback later is instant.
  Future<void> _toggleSongFavorite(BuildContext context, DashboardProvider provider) async {
    final title = provider.currentTrack;
    final artist = provider.currentArtist;
    if (title.isEmpty || title == 'Not Playing') return;
    if (provider.isSongFavorited(title)) {
      provider.removeFavoriteTyped(title, 'song');
      return;
    }
    String videoId = '';
    String thumbnail = '';
    try {
      final results = await context.read<YouTubeService>().searchYTMusicSongs('$title $artist', limit: 1);
      if (results.isNotEmpty) {
        videoId = results.first['videoId'] ?? '';
        thumbnail = results.first['thumbnail'] ?? '';
      }
    } catch (_) {}
    provider.addSongFavorite(title: title, artist: artist, videoId: videoId, thumbnail: thumbnail);
  }

  Widget _buildControlButton({
    required IconData icon,
    required double size,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.04),
            shape: BoxShape.circle,
            border: Border.all(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08)),
          ),
          child: Icon(
            icon,
            color: Theme.of(context).colorScheme.onSurface,
            size: size,
          ),
        ),
      ),
    );
  }

  Widget _buildPlayPauseButton({
    required bool isPlaying,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurface,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Theme.of(context).colorScheme.surface,
            size: 32,
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// FAVORITES SIDEBAR WIDGET
// ----------------------------------------------------------------------------
class FavoritesSidebar extends StatefulWidget {
  const FavoritesSidebar({super.key});

  @override
  State<FavoritesSidebar> createState() => _FavoritesSidebarState();
}

class _FavoritesSidebarState extends State<FavoritesSidebar> {
  bool _showQueue = false;
  // Active type filter for the favorites list: 'all' | 'song' | 'album' | 'artist'.
  String _favFilter = 'all';

  IconData _iconForFavoriteType(String? type, IconData fallback) {
    switch (type) {
      case 'song':
        return Icons.music_note;
      case 'album':
        return Icons.album;
      case 'artist':
        return Icons.interpreter_mode;
      case 'playlist':
        return Icons.queue_music;
      default:
        return fallback;
    }
  }

  /// Plays a favorite by type: song → direct (no flash); album/artist → fetch
  /// tracks natively into the queue; playlist/legacy or a failed native fetch →
  /// fall back to launching YT Music.
  /// After starting playback into our queue, flip the sidebar to the queue view
  /// so the user sees what's playing (not for the legacy YT-Music launch path).
  void _goToQueueView() {
    if (mounted && !_showQueue) setState(() => _showQueue = true);
  }

  Future<void> _playFavorite(BuildContext context, Map<String, String> fav, {String artistMode = 'radio'}) async {
    final type = fav['type'] ?? 'playlist';
    final collab = context.read<CollabService>();
    final yt = context.read<YouTubeService>();
    final messenger = ScaffoldMessenger.of(context);

    if (type == 'song') {
      final vid = fav['videoId'] ?? '';
      if (vid.isNotEmpty) {
        collab.playFavoriteSong(
          videoId: vid,
          title: fav['title'] ?? '',
          artist: fav['subtitle'] ?? '',
          thumbnail: fav['thumbnail'] ?? '',
        );
        _goToQueueView();
        return;
      }
    } else if (type == 'album') {
      messenger.showSnackBar(SnackBar(content: Text('Loading album "${fav['title']}"…'), duration: const Duration(seconds: 2)));
      final tracks = await yt.getAlbumTracks(fav['title'] ?? '', fav['subtitle'] ?? '');
      if (tracks.isNotEmpty) {
        await collab.loadQueueAndPlay(tracks, resolveAudio: true);
        _goToQueueView();
        return;
      }
    } else if (type == 'artist') {
      final name = fav['title'] ?? fav['subtitle'] ?? '';
      final isRadio = artistMode == 'radio';
      messenger.showSnackBar(SnackBar(
        content: Text(isRadio ? 'Starting $name radio…' : 'Playing $name…'),
        duration: const Duration(seconds: 2),
      ));
      final tracks = isRadio
          ? await yt.getArtistRadioTracks(name)
          : await yt.getArtistTracks(name);
      if (tracks.isNotEmpty) {
        await collab.loadQueueAndPlay(tracks);
        _goToQueueView();
        return;
      }
    }

    // Fallback: legacy YT Music launch (playlist type, missing id, or fetch failed).
    if (context.mounted) {
      _launchPlaylist(context, fav['url'] ?? fav['title'] ?? '');
    }
  }

  Future<void> _launchPlaylist(BuildContext context, String queryOrUrl) async {
    final isUrl = queryOrUrl.startsWith('http');
    final provider = Provider.of<DashboardProvider>(context, listen: false);
    
    // WARM-UP HACK: YouTube Music drops search intents on cold start. 
    // We explicitly launch the package first to warm it up in the background.
    if (!isUrl) {
      try {
        final warmup = AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: 'com.google.android.apps.youtube.music',
        );
        await warmup.launch();
        await Future.delayed(const Duration(milliseconds: 800));
      } catch (e) {
        debugPrint("Warmup failed: $e");
      }
    }
    
    // 1. Try launching YouTube Music explicitly
    final intent = isUrl 
      ? AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: queryOrUrl,
          package: 'com.google.android.apps.youtube.music', 
        )
      : AndroidIntent(
          action: 'android.media.action.MEDIA_PLAY_FROM_SEARCH',
          package: 'com.google.android.apps.youtube.music',
          arguments: <String, dynamic>{
            'query': queryOrUrl,
          },
        );
    
    try {
      await intent.launch();
      provider.setWaitingForMusic();
    } catch (e) {
      debugPrint("YT Music explicitly failed: $e. Falling back to global search intent.");
      // 2. Fallback to global media search (will show chooser with all music apps)
      if (!isUrl) {
         final fallbackIntent = AndroidIntent(
            action: 'android.media.action.MEDIA_PLAY_FROM_SEARCH',
            arguments: <String, dynamic>{
              'query': queryOrUrl,
            },
         );
         try {
           await fallbackIntent.launch();
           provider.setWaitingForMusic();
         } catch (fallbackErr) {
           debugPrint("Global fallback failed: $fallbackErr");
         }
      }
    }
  }

  final List<Color> startColors = [const Color(0xFF6A1B9A), const Color(0xFFBF360C), const Color(0xFF004D40)];
  final List<Color> endColors = [const Color(0xFF8E24AA), const Color(0xFFE64A19), const Color(0xFF00796B)];
  final List<IconData> icons = [Icons.nightlife, Icons.bolt, Icons.explore_outlined];

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sidebar Header
        Padding(
          padding: const EdgeInsets.only(bottom: 2.0, left: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Container(
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _showQueue = false),
                          child: Container(
                            decoration: BoxDecoration(
                              color: !_showQueue ? theme.colorScheme.primary : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: Text(
                                "FAVORITES", 
                                style: TextStyle(
                                  color: !_showQueue ? Colors.white : onSurface.withOpacity(0.6), 
                                  fontSize: 10, 
                                  fontWeight: FontWeight.bold, 
                                  letterSpacing: 1.2
                                )
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _showQueue = true),
                          child: Container(
                            decoration: BoxDecoration(
                              color: _showQueue ? theme.colorScheme.primary : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: Text(
                                "QUEUE",
                                style: TextStyle(
                                  color: _showQueue ? Colors.white : onSurface.withOpacity(0.6),
                                  fontSize: 10, 
                                  fontWeight: FontWeight.bold, 
                                  letterSpacing: 1.2
                                )
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        
        Expanded(
          child: _showQueue
              ? const QueueTab()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Pinned type filter (All / Songs / Albums / Artists) — always
                    // reachable so you can switch without scrolling to the top.
                    _buildFilterChips(theme, onSurface, provider),
                    Expanded(child: _buildFavoritesList(context, theme, onSurface, provider)),
                  ],
                ),
        ),
      ],
    );
  }

  /// The pinned row of type-filter chips above the favorites list.
  Widget _buildFilterChips(ThemeData theme, Color onSurface, DashboardProvider provider) {
    final favs = provider.favorites;
    int countOf(String t) => favs.where((f) => (f['type'] ?? '') == t).length;
    final entries = <List<String>>[
      ['all', 'All'],
      ['song', 'Songs'],
      ['album', 'Albums'],
      ['artist', 'Artists'],
    ];
    final counts = {
      'all': favs.length,
      'song': countOf('song'),
      'album': countOf('album'),
      'artist': countOf('artist'),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2.0, bottom: 6.0),
      child: Row(
        children: [
          for (final e in entries)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: e[0] == 'artist' ? 0 : 5.0),
                child: _favFilterChip(theme, onSurface, e[0], e[1], counts[e[0]]!),
              ),
            ),
        ],
      ),
    );
  }

  Widget _favFilterChip(ThemeData theme, Color onSurface, String key, String label, int count) {
    final active = _favFilter == key;
    return GestureDetector(
      onTap: () => setState(() => _favFilter = key),
      child: Container(
        height: 28,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: active ? theme.colorScheme.primary : onSurface.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            count > 0 ? '$label  $count' : label,
            maxLines: 1,
            style: TextStyle(
              color: active ? Colors.white : onSurface.withOpacity(0.7),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }

  /// The favorites list for the active filter. The personalized mix grid rides
  /// on top as a scroll-away header, but only in the unfiltered "All" view.
  Widget _buildFavoritesList(BuildContext context, ThemeData theme, Color onSurface, DashboardProvider provider) {
    final showMixGrid = _favFilter == 'all';
    final visible = showMixGrid
        ? provider.favorites
        : provider.favorites.where((f) => (f['type'] ?? '') == _favFilter).toList();

    if (visible.isEmpty && !showMixGrid) {
      final label = _favFilter == 'song'
          ? 'songs'
          : _favFilter == 'album'
              ? 'albums'
              : 'artists';
      return Center(
        child: Text(
          'No $label favorited yet',
          style: TextStyle(color: onSurface.withOpacity(0.4), fontSize: 12),
        ),
      );
    }

    final header = showMixGrid ? 1 : 0;
    return ListView.builder(
      itemCount: visible.length + header,
      itemBuilder: (context, index) {
        if (showMixGrid && index == 0) {
          // Personalized mix grid (YT Music home feed).
          return Padding(
            padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
            child: _buildMixGrid(context, theme, onSurface),
          );
        }
        final favIndex = index - header;
        final fav = visible[favIndex];
        final isArtist = (fav['type'] ?? '') == 'artist';
        return Padding(
          padding: EdgeInsets.only(bottom: favIndex == visible.length - 1 ? 0 : 8.0),
          child: _PlaylistCard(
            title: fav['title'] ?? 'Unknown',
            subtitle: fav['subtitle'] ?? 'YouTube Music',
            startColor: startColors[favIndex % startColors.length],
            endColor: endColors[favIndex % endColors.length],
            icon: _iconForFavoriteType(fav['type'], icons[favIndex % icons.length]),
            onTap: isArtist ? null : () => _playFavorite(context, fav),
            onRadioTap: isArtist ? () => _playFavorite(context, fav, artistMode: 'radio') : null,
            onArtistTap: isArtist ? () => _playFavorite(context, fav, artistMode: 'artist') : null,
            // Remove by identity (title+type) so it targets the right entry even
            // when the list is filtered (index no longer maps to provider index).
            onLongPress: () => provider.removeFavoriteTyped(fav['title'] ?? '', fav['type'] ?? ''),
          ),
        );
      },
    );
  }

  bool _tilesRequested = false;

  Widget _buildMixGrid(BuildContext context, ThemeData theme, Color onSurface) {
    final yt = context.watch<YouTubeService>();
    if (!yt.isYtmLoggedIn) {
      _tilesRequested = false;
      return GestureDetector(
        onTap: () => _connectYtMusic(context),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.primary.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.library_music, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                "Connect YouTube Music",
                style: TextStyle(color: theme.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
    }
    final tiles = yt.homeTiles;
    if (tiles.isEmpty && !_tilesRequested) {
      _tilesRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => yt.fetchHomeTiles());
    }
    final children = tiles.isEmpty
        ? List.generate(4, (_) => _mixSkeleton(onSurface))
        : [for (final t in tiles.take(4)) _MixTile(tile: t, onTap: () => _playMix(context, t))];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.6,
      children: children,
    );
  }

  Widget _mixSkeleton(Color onSurface) => Container(
        decoration: BoxDecoration(
          color: onSurface.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
      );

  Future<void> _connectYtMusic(BuildContext context) async {
    final yt = context.read<YouTubeService>();
    final result = await Navigator.of(context).push<Map>(
      MaterialPageRoute(builder: (_) => const YtMusicLoginWebView()),
    );
    if (result != null && result['cookie'] != null && result['sapisid'] != null) {
      await yt.setYtmAuth(result['cookie'].toString(), result['sapisid'].toString());
      await yt.fetchHomeTiles();
    }
  }

  Future<void> _playMix(BuildContext context, HomeTile tile) async {
    final yt = context.read<YouTubeService>();
    final collab = context.read<CollabService>();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Loading ${tile.title}…'), duration: const Duration(seconds: 2)));
    final tracks = await yt.getMixTracks(tile);
    if (tracks.isNotEmpty) {
      await collab.loadQueueAndPlay(tracks);
      _goToQueueView();
    } else if (context.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not load that mix')));
    }
  }
}

/// A mix block in the favorites-screen grid: cover art + label, tap to play.
class _MixTile extends StatelessWidget {
  final HomeTile tile;
  final VoidCallback onTap;
  const _MixTile({required this.tile, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (tile.thumbnail.isNotEmpty)
              Image.network(
                tile.thumbnail,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(color: Colors.grey.withOpacity(0.25)),
              )
            else
              Container(color: Colors.grey.withOpacity(0.25)),
            // Bottom scrim for label legibility.
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.75)],
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Text(
                tile.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final Color startColor;
  final Color endColor;
  final IconData icon;
  /// Single-tap play (song/album/playlist). Null for artist cards, which use
  /// [onRadioTap]/[onArtistTap] and reveal a Radio/Artist choice on tap instead.
  final VoidCallback? onTap;
  final VoidCallback? onRadioTap;
  final VoidCallback? onArtistTap;
  final VoidCallback? onLongPress;

  const _PlaylistCard({
    required this.title,
    required this.subtitle,
    required this.startColor,
    required this.endColor,
    required this.icon,
    this.onTap,
    this.onRadioTap,
    this.onArtistTap,
    this.onLongPress,
  });

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> with SingleTickerProviderStateMixin {
  double _scale = 1.0;
  bool _showChoice = false;

  bool get _hasChoice => widget.onRadioTap != null || widget.onArtistTap != null;

  void _handleTap() {
    if (_hasChoice) {
      setState(() => _showChoice = !_showChoice);
    } else {
      widget.onTap?.call();
    }
  }

  Widget _choiceButton(String label, IconData icon, VoidCallback? onTap, ThemeData theme) {
    return GestureDetector(
      onTap: () {
        setState(() => _showChoice = false);
        onTap?.call();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: theme.colorScheme.primary, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.96),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: _handleTap,
      onLongPress: widget.onLongPress,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
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

                // When showing the artist choice, collapse the text to make room.
                if (_hasChoice && _showChoice) ...[
                  _choiceButton('Radio', Icons.radio, widget.onRadioTap, theme),
                  const SizedBox(width: 6),
                  _choiceButton('Artist', Icons.person, widget.onArtistTap, theme),
                  const Spacer(),
                  Icon(Icons.close, color: onSurface.withOpacity(0.5), size: 18),
                ] else ...[
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
                    _hasChoice ? Icons.more_horiz : Icons.play_circle_outline,
                    color: onSurface.withOpacity(0.8),
                    size: 20,
                  ),
                ],
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

class CellularIconWidget extends StatelessWidget {
  final int bars;
  final Color color;
  final double size;

  const CellularIconWidget({
    super.key,
    required this.bars,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (index) {
          final isActive = index < bars;
          return Container(
            width: size * 0.16,
            height: size * (0.4 + (index * 0.2)),
            decoration: BoxDecoration(
              color: isActive ? color : color.withOpacity(0.3),
              borderRadius: BorderRadius.circular(size * 0.05),
            ),
          );
        }),
      ),
    );
  }
}

class ThickBrightnessSlider extends StatelessWidget {
  final int brightness; // 0-255
  final bool isAdaptive;
  final ValueChanged<int> onChanged;
  final VoidCallback onToggleAdaptive;
  final Color activeColor;
  final Color backgroundColor;
  final Color iconColor;

  const ThickBrightnessSlider({
    super.key,
    required this.brightness,
    required this.isAdaptive,
    required this.onChanged,
    required this.onToggleAdaptive,
    required this.activeColor,
    required this.backgroundColor,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) {
        if (isAdaptive) return;
        final RenderBox box = context.findRenderObject() as RenderBox;
        final localPos = box.globalToLocal(details.globalPosition);
        final width = box.size.width;
        if (width <= 0) return;
        double percentage = (localPos.dx / width).clamp(0.0, 1.0);
        onChanged((percentage * 255).toInt());
      },
      onTapDown: (details) {
        if (isAdaptive) return;
        final RenderBox box = context.findRenderObject() as RenderBox;
        final localPos = box.globalToLocal(details.globalPosition);
        final width = box.size.width;
        if (width <= 0) return;
        double percentage = (localPos.dx / width).clamp(0.0, 1.0);
        onChanged((percentage * 255).toInt());
      },
      child: Container(
        width: double.infinity, // stretch to fill parent Expanded
        height: 32, // thick
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              // Filled portion
              if (!isAdaptive)
                FractionallySizedBox(
                  widthFactor: (brightness / 255.0).clamp(0.0, 1.0),
                  heightFactor: 1.0,
                  child: Container(color: activeColor),
                ),
              // If adaptive, fill lightly to indicate "auto"
              if (isAdaptive)
                Container(color: activeColor.withOpacity(0.2)),

              // Embedded Icon (acting as the toggle)
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: onToggleAdaptive,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10.0),
                    child: Icon(
                      isAdaptive ? Icons.brightness_auto : Icons.brightness_medium,
                      size: 16,
                      color: isAdaptive ? activeColor : (brightness > 180 ? backgroundColor : iconColor), 
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
