import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart'; // For DashboardProvider

class WelcomeOverlayWidget extends StatefulWidget {
  const WelcomeOverlayWidget({super.key});

  @override
  State<WelcomeOverlayWidget> createState() => _WelcomeOverlayWidgetState();
}

class _WelcomeOverlayWidgetState extends State<WelcomeOverlayWidget> {
  final TextEditingController _destinationController = TextEditingController();
  final TextEditingController _mediaController = TextEditingController();
  String _stagedDestination = "";
  String _stagedMediaUrl = "";
  bool _startDashcam = false;
  bool _startDashcamDefault = false;

  static const platform = MethodChannel('com.example.car_dashboard/system');

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _startDashcamDefault = prefs.getBool('startDashcamWelcomeDefault') ?? false;
      _startDashcam = prefs.getBool('startDashcamWelcome') ?? false;
    });
  }

  void _stageDestination(String query) {
    setState(() {
      _stagedDestination = query;
      _destinationController.text = query;
    });
  }

  void _stageMedia(String queryOrUrl, String label) {
    setState(() {
      _stagedMediaUrl = queryOrUrl;
      _mediaController.text = label;
    });
  }

  Future<void> _handleLetsGo() async {
    final provider = Provider.of<DashboardProvider>(context, listen: false);
    
    final destText = _destinationController.text;
    if (destText.isNotEmpty && _stagedDestination.isEmpty) {
      _stagedDestination = destText;
    }
    
    final mediaText = _mediaController.text;
    if (mediaText.isNotEmpty && _stagedMediaUrl.isEmpty) {
      _stagedMediaUrl = mediaText;
    }

    if (_startDashcamDefault || _startDashcam) {
      try {
        await platform.invokeMethod('startDashcam');
        await Future.delayed(const Duration(milliseconds: 1000)); // give dashcam time to start
      } catch (e) {
        debugPrint("Dashcam launch failed: $e");
      }
    }

    bool launchedMaps = false;
    if (_stagedDestination.isNotEmpty) {
      await _launchMaps(_stagedDestination);
      launchedMaps = true;
    }

    if (launchedMaps) {
      int attempts = 0;
      // Wait up to ~12s (24 * 500ms) for the user to start navigation, then bring
      // the app back. Capped low so music + overlay dismissal aren't held hostage
      // if the user never starts a route. Bail immediately if the overlay is gone.
      while (attempts < 24) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        try {
          final isNavigating = await platform.invokeMethod<bool>('isNavigating');
          if (isNavigating == true) {
            // Give Maps one extra second to finish drawing its navigation UI before we yank the app back
            await Future.delayed(const Duration(seconds: 1));
            break;
          }
        } catch (e) {
          // Ignore platform exceptions
        }
        attempts++;
      }
      if (!mounted) return;

      try {
        await platform.invokeMethod('bringToFront');
      } catch (e) {
        debugPrint("Bring to front failed: $e");
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (_stagedMediaUrl.isNotEmpty) {
      await _launchMedia(provider, _stagedMediaUrl);
    }

    provider.dismissWelcomeUI();
  }

  Future<void> _launchMaps(String query) async {
    if (query.isEmpty) return;
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'google.navigation:q=$query',
        package: 'com.google.android.apps.maps',
      );
      await intent.launch();
    } catch (e) {
      debugPrint("Maps launch failed: $e");
      // Fallback without package if Maps is not installed/disabled
      try {
        final fallbackIntent = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: 'google.navigation:q=$query',
        );
        await fallbackIntent.launch();
      } catch (e2) {
        debugPrint("Maps fallback failed: $e2");
      }
    }
  }

  // Takes the provider directly (not context) so it is safe to call after the
  // long maps/nav awaits, when this widget's context may already be defunct.
  Future<void> _launchMedia(DashboardProvider provider, String queryOrUrl) async {
    if (queryOrUrl.isEmpty) return;

    final isUrl = queryOrUrl.startsWith('http');
    
    // Warm-up
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
      debugPrint("YT Music explicitly failed: $e");
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

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Positioned.fill(
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: GestureDetector(
            onTap: provider.dismissWelcomeUI,
            behavior: HitTestBehavior.opaque,
            child: Container(
              color: theme.scaffoldBackgroundColor.withOpacity(0.4),
              child: Center(
                child: SingleChildScrollView(
                  child: GestureDetector(
                    onTap: () {}, // Consume taps inside the popup
                    child: Container(
                      width: MediaQuery.of(context).size.width * 0.8,
                      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: onSurface.withOpacity(0.1)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Ready to drive?",
                        style: TextStyle(
                          color: onSurface,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Where are we heading and what are we listening to?",
                        style: TextStyle(
                          color: onSurface.withOpacity(0.6),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Destination Column
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.place, color: theme.colorScheme.primary, size: 20),
                                    const SizedBox(width: 8),
                                    Text("DESTINATION", style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _destinationController,
                                  style: TextStyle(color: onSurface),
                                  decoration: InputDecoration(
                                    hintText: "Search Google Maps...",
                                    hintStyle: TextStyle(color: onSurface.withOpacity(0.4)),
                                    prefixIcon: Icon(Icons.search, color: onSurface.withOpacity(0.4)),
                                    filled: true,
                                    fillColor: onSurface.withOpacity(0.05),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      borderSide: BorderSide.none,
                                    ),
                                    suffixIcon: IconButton(
                                      icon: const Icon(Icons.check_circle_outline),
                                      color: theme.colorScheme.primary,
                                      onPressed: () => _stageDestination(_destinationController.text),
                                    ),
                                  ),
                                  onSubmitted: _stageDestination,
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _ShortcutButton(
                                        icon: Icons.home,
                                        label: "Home",
                                        onTap: () => _stageDestination("Home"),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _ShortcutButton(
                                        icon: Icons.work,
                                        label: "Work",
                                        onTap: () => _stageDestination("Work"),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          
                          Container(
                            width: 1,
                            margin: const EdgeInsets.symmetric(horizontal: 24),
                            color: onSurface.withOpacity(0.1),
                          ),
                          
                          // Media Column
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.music_note, color: theme.colorScheme.secondary, size: 20),
                                    const SizedBox(width: 8),
                                    Text("MEDIA", style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _mediaController,
                                  style: TextStyle(color: onSurface),
                                  decoration: InputDecoration(
                                    hintText: "Search YouTube Music...",
                                    hintStyle: TextStyle(color: onSurface.withOpacity(0.4)),
                                    prefixIcon: Icon(Icons.search, color: onSurface.withOpacity(0.4)),
                                    filled: true,
                                    fillColor: onSurface.withOpacity(0.05),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      borderSide: BorderSide.none,
                                    ),
                                    suffixIcon: IconButton(
                                      icon: const Icon(Icons.check_circle_outline),
                                      color: theme.colorScheme.secondary,
                                      onPressed: () => _stageMedia(_mediaController.text, _mediaController.text),
                                    ),
                                  ),
                                  onSubmitted: (val) => _stageMedia(val, val),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 52,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: provider.favorites.length > 4 ? 4 : provider.favorites.length,
                                    itemBuilder: (context, index) {
                                      final fav = provider.favorites[index];
                                      return Padding(
                                        padding: const EdgeInsets.only(right: 12.0),
                                        child: _ShortcutButton(
                                          icon: Icons.library_music,
                                          label: fav['title'] ?? 'Playlist',
                                          isCompact: true,
                                          onTap: () => _stageMedia(fav['url'] ?? '', fav['title'] ?? 'Playlist'),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      ),
                      
                      const SizedBox(height: 24),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Dashcam Controls
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.camera_alt, color: onSurface.withOpacity(0.7), size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    "Start Dashcam",
                                    style: TextStyle(
                                      color: onSurface.withOpacity(0.9),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Switch(
                                    value: _startDashcamDefault ? true : _startDashcam,
                                    onChanged: _startDashcamDefault 
                                      ? null 
                                      : (val) async {
                                          setState(() => _startDashcam = val);
                                          final prefs = await SharedPreferences.getInstance();
                                          await prefs.setBool('startDashcamWelcome', val);
                                        },
                                    activeColor: theme.colorScheme.primary,
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    "Start by default",
                                    style: TextStyle(
                                      color: onSurface.withOpacity(0.6),
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: Checkbox(
                                      value: _startDashcamDefault,
                                      activeColor: theme.colorScheme.primary,
                                      onChanged: (val) async {
                                        if (val != null) {
                                          setState(() => _startDashcamDefault = val);
                                          final prefs = await SharedPreferences.getInstance();
                                          await prefs.setBool('startDashcamWelcomeDefault', val);
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          
                          // START DRIVE Button
                          SizedBox(
                            width: 180,
                            height: 44,
                            child: ElevatedButton(
                              onPressed: _handleLetsGo,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.onPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                elevation: 4,
                              ),
                              child: const Text(
                                "START DRIVE",
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isCompact;

  const _ShortcutButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 12 : 10, 
          vertical: isCompact ? 0 : 10
        ),
        decoration: BoxDecoration(
          color: onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: onSurface.withOpacity(0.1)),
        ),
        child: isCompact 
          ? Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: onSurface.withOpacity(0.7), size: 16),
                  const SizedBox(width: 8),
                  Text(
                    label.length > 15 ? '${label.substring(0, 12)}...' : label,
                    style: TextStyle(color: onSurface, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: onSurface.withOpacity(0.7), size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(color: onSurface, fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ],
            ),
      ),
    );
  }
}
