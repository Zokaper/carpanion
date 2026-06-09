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
      if (_callNumber.isNotEmpty && _callName.isEmpty) {
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
      } else if (stateStr == 'RINGING' || stateStr == 'DIALING' || stateStr == 'CONNECTING') {
        // Automatically switch sidebar tab to the Phone Tab (index 1) to show caller UI
        if (_selectedSidebarTab != 1) {
          _selectedSidebarTab = 1;
        }
      }
    }
    notifyListeners();
  }

  Future<String> _resolveContactName(String number) async {
    try {
      final cleanNumber = number.replaceAll(RegExp(r'\D'), '');
      if (cleanNumber.isEmpty) return 'Unknown Caller';
      
      final contacts = await FlutterContacts.getAll(properties: ContactProperties.all);
      for (final contact in contacts) {
        for (final phone in contact.phones) {
          final cleanPhone = phone.number.replaceAll(RegExp(r'\D'), '');
          if (cleanPhone == cleanNumber || (cleanPhone.endsWith(cleanNumber) && cleanNumber.length >= 7)) {
            final name = contact.displayName;
            return (name != null && name.isNotEmpty) ? name : (number.isNotEmpty ? number : 'Unknown Caller');
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
        final query = '[out:json];way(around:100,$lat,$lon)["maxspeed"];out tags;';
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
          child: Column(
            children: [
              // Top Header Bar
              const HeaderBarWidget(),
              const SizedBox(height: 10),
              
              // Warning banner if permissions/services are missing
              if (provider.errorMessage.isNotEmpty && !provider.isDemoMode)
                Container(
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
                          provider.errorMessage,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                      TextButton(
                        onPressed: provider.checkLocationSettingsAndPermissions,
                        child: const Text("RETRY", style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: provider.toggleDemoMode,
                        child: const Text("USE DEMO MODE", style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
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
                    
                    // Center Column: Media Control Panel
                    const Expanded(
                      flex: 8,
                      child: MediaControlPanel(),
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
    );
  }
}

// ----------------------------------------------------------------------------
// HEADER BAR WIDGET
// ----------------------------------------------------------------------------
class HeaderBarWidget extends StatelessWidget {
  const HeaderBarWidget({super.key});

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
    final provider = Provider.of<DashboardProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      child: Row(
        children: [
          // Left Column Header (Flex 7): App Title & Time
          Expanded(
            flex: 7,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.speed, color: onSurface, size: 28),
                    const SizedBox(width: 12),
                  ],
                ),
                StreamBuilder<DateTime>(
                  stream: Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()),
                  initialData: DateTime.now(),
                  builder: (context, snapshot) {
                    final now = snapshot.data ?? DateTime.now();
                    return Row(
                      children: [
                        Text(
                          _formatTime(now),
                          style: TextStyle(
                            color: onSurface,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(width: 1, height: 12, color: onSurface.withOpacity(0.24)),
                        const SizedBox(width: 10),
                        Text(
                          "${_getWeekdayName(now.weekday)}, ${_getMonthName(now.month)} ${now.day}",
                          style: TextStyle(
                            color: onSurface.withOpacity(0.6),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          
          // Center Column Header (Flex 8): Settings
          Expanded(
            flex: 8,
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => const SettingsDialog(),
                  );
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

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final isPlaying = provider.isPlaying;
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    // Logic handled natively now

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: onSurface.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.music_note, color: theme.colorScheme.primary, size: 12),
              const SizedBox(width: 6),
              Text(
                "SYSTEM MEDIA",
                style: TextStyle(
                  color: onSurface.withOpacity(0.6),
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => provider.requestMediaPermissions(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                     color: onSurface.withOpacity(0.1),
                     borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text("SYNC", style: TextStyle(color: onSurface, fontSize: 8, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Large Album Art on Top (Takes maximum space)
          Expanded(
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
                  child: provider.currentAlbumArtBytes != null
                      ? Image.memory(
                          provider.currentAlbumArtBytes!, 
                          fit: BoxFit.cover, 
                          errorBuilder: (c, e, s) => Icon(Icons.music_video_rounded, color: onSurface.withOpacity(0.2), size: 60)
                        )
                      : Center(
                          child: Icon(Icons.music_video_rounded, color: onSurface.withOpacity(0.2), size: 60),
                        ),
                );
              },
            ),
          ),
          
          const SizedBox(height: 12),
          
          // Track Info
          Text(
            provider.currentTrack,
            style: TextStyle(
              color: onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            provider.currentArtist,
            style: TextStyle(
              color: onSurface.withOpacity(0.6),
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          
          const SizedBox(height: 12),
          
          // Real Native Progress Bar
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: theme.colorScheme.primary,
              inactiveTrackColor: onSurface.withOpacity(0.1),
              thumbColor: theme.colorScheme.primary,
              trackHeight: 4.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
              overlayColor: theme.colorScheme.primary.withOpacity(0.2),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16.0),
            ),
            child: Slider(
              value: provider.mediaPosition.clamp(0.0, provider.mediaDuration),
              min: 0.0,
              max: provider.mediaDuration,
              onChanged: (value) {
                // Seek not supported natively through this plugin yet
              },
            ),
          ),
          
          const SizedBox(height: 12),

          // Control Buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlButton(
                icon: Icons.skip_previous_rounded,
                size: 26,
                onPressed: () {
                  _handleMediaAction('previous');
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
                  _handleMediaAction('next');
                },
              ),
            ],
          ),
        ],
      ),
    );
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
  List<Map<String, String>> _favorites = [
    {
      'title': 'My Supermix',
      'url': 'My Supermix'
    },
    {
      'title': 'Chill Beats',
      'url': 'Chill Beats'
    },
    {
      'title': 'Driving Anthems',
      'url': 'Driving Anthems'
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final titles = prefs.getStringList('fav_titles');
    final urls = prefs.getStringList('fav_urls');
    
    if (titles != null && urls != null && titles.length == urls.length && titles.isNotEmpty) {
      setState(() {
        _favorites = List.generate(titles.length, (i) => {
          'title': titles[i],
          'url': urls[i],
        });
      });
    }
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('fav_titles', _favorites.map((e) => e['title']!).toList());
    await prefs.setStringList('fav_urls', _favorites.map((e) => e['url']!).toList());
  }

  void _editFavorites() {
    showDialog(
      context: context,
      builder: (context) {
        final List<TextEditingController> titleControllers = _favorites.map((f) => TextEditingController(text: f['title'])).toList();
        final List<TextEditingController> urlControllers = _favorites.map((f) => TextEditingController(text: f['url'])).toList();
        
        return AlertDialog(
          backgroundColor: const Color(0xFF151525),
          title: const Text("Edit Favorites", style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(titleControllers.length, (i) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: titleControllers[i],
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(labelText: "Name", labelStyle: TextStyle(color: Colors.white54)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: urlControllers[i],
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(labelText: "Search Query (e.g. My Supermix) or URL", labelStyle: TextStyle(color: Colors.white54)),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CANCEL"),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  for (int i = 0; i < _favorites.length; i++) {
                    _favorites[i]['title'] = titleControllers[i].text;
                    _favorites[i]['url'] = urlControllers[i].text;
                  }
                });
                _saveFavorites();
                Navigator.pop(context);
              },
              child: const Text("SAVE", style: TextStyle(color: Color(0xFF00E5FF))),
            ),
          ],
        );
      }
    );
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
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sidebar Header
        Padding(
          padding: const EdgeInsets.only(bottom: 6.0, left: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "QUICK FAVORITES",
                style: TextStyle(
                  color: onSurface.withOpacity(0.6),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              GestureDetector(
                onTap: _editFavorites,
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Icon(Icons.edit, color: onSurface.withOpacity(0.5), size: 14),
                ),
              ),
            ],
          ),
        ),
        
        ...List.generate(_favorites.length, (index) {
           return Expanded(
             child: Padding(
               padding: EdgeInsets.only(bottom: index == _favorites.length - 1 ? 0 : 8.0),
               child: _PlaylistCard(
                 title: _favorites[index]['title']!,
                 subtitle: 'YouTube Music Playlist',
                 startColor: startColors[index % startColors.length],
                 endColor: endColors[index % endColors.length],
                 icon: icons[index % icons.length],
                 onTap: () => _launchPlaylist(context, _favorites[index]['url']!),
               ),
             ),
           );
        }),
      ],
    );
  }
}

class _PlaylistCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final Color startColor;
  final Color endColor;
  final IconData icon;
  final VoidCallback onTap;

  const _PlaylistCard({
    required this.title,
    required this.subtitle,
    required this.startColor,
    required this.endColor,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> with SingleTickerProviderStateMixin {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.96),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
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
