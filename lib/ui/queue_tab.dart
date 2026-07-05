import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_media_controller/flutter_media_controller.dart';
import '../services/youtube_service.dart';
import '../main.dart';

class QueueTab extends StatefulWidget {
  const QueueTab({super.key});

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  final String backendUrl = "https://carpanion.onrender.com";
  static String? _persistedSessionId;
  late String sessionId;
  IO.Socket? socket;
  final List<String> _recentlyAdded = [];
  bool _queueStarted = false;
  bool _showQrCodeOverlay = false;
  bool _allowEditing = false;
  bool _allowMediaControl = false;
  late YouTubeService _ytService;
  late DashboardProvider _dashboard;
  Timer? _pollTimer;
  String _lastTrack = '';
  
  final ScrollController _scrollController = ScrollController();
  bool _userScrolled = false;

  @override
  void initState() {
    super.initState();
    if (_persistedSessionId == null) {
      _persistedSessionId = _generateSessionId();
    }
    sessionId = _persistedSessionId!;
    _ytService = Provider.of<YouTubeService>(context, listen: false);
    _dashboard = Provider.of<DashboardProvider>(context, listen: false);
    
    _ytService.addListener(_onYouTubeServiceUpdate);
    _dashboard.addListener(_onDashboardUpdate);
    
    _connectSocket();
    
    // Initial fetch and start polling every 10 seconds to catch external edits
    _ytService.fetchQueue();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _ytService.fetchQueue();
    });
  }

  void _onDashboardUpdate() {
    if (_dashboard.currentTrack != _lastTrack) {
      if (mounted) {
        setState(() {
          _lastTrack = _dashboard.currentTrack;
        });
      } else {
        _lastTrack = _dashboard.currentTrack;
      }
      
      if (socket?.connected == true) {
        socket!.emit('update_playing_status', _lastTrack);
      }
      _scrollToPlayingTrack();
    }
  }

  void _scrollToPlayingTrack() {
    if (_userScrolled || !_scrollController.hasClients) return;
    int index = _ytService.currentQueue.indexWhere((item) {
      final qTitle = (item['title'] ?? '').toLowerCase();
      final dTitle = _lastTrack.toLowerCase();
      return qTitle == dTitle || qTitle.contains(dTitle) || dTitle.contains(qTitle);
    });
    if (index != -1) {
      // Calculate approximate position to center the item (approx 60px height per item)
      final position = (index * 60.0) - (150.0);
      _scrollController.animateTo(
        position > 0 ? position : 0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onYouTubeServiceUpdate() {
    if (socket?.connected == true) {
      socket!.emit('update_queue', jsonEncode(_ytService.currentQueue));
    }
  }

  String _generateSessionId() {
    final rand = Random();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(6, (index) => chars[rand.nextInt(chars.length)]).join();
  }

  void _connectSocket() {
    socket = IO.io(backendUrl, IO.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .build()
    );

    socket!.connect();

    socket!.onConnect((_) {
      debugPrint("Connected to backend, registering session: $sessionId");
      socket!.emit('register_session', sessionId);
    });

    socket!.on('add_song', (data) async {
      debugPrint("Received add_song event: $data");
      if (data['videoId'] != null) {
        final title = data['title'] ?? 'Unknown Song';
        final success = await _ytService.addVideoToPlaylist(data['videoId']);
        if (success && mounted) {
          setState(() {
            _recentlyAdded.insert(0, title);
            if (_recentlyAdded.length > 5) _recentlyAdded.removeLast();
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added to Queue: $title'), duration: const Duration(seconds: 2)),
          );
          if (!_queueStarted && _ytService.playlistId != null) {
            _playQueue(_ytService.playlistId!);
          }
        }
      }
    });

    socket!.on('request_queue', (_) {
      socket!.emit('update_queue', jsonEncode(_ytService.currentQueue));
    });

    socket!.on('request_permissions', (_) {
      socket!.emit('update_permissions', _allowEditing);
      socket!.emit('update_media_permissions', _allowMediaControl);
    });

    socket!.on('passenger_media_action', (action) async {
      if (_allowMediaControl) {
        try {
          if (action == 'playPause') {
            await FlutterMediaController.togglePlayPause();
          } else if (action == 'next') {
            // Anti-endless mode throttling: If the currently playing track is right before the newly added tracks,
            // we ignore the skip to give YouTube Music time to sync the playlist from the cloud.
            int playingIndex = _ytService.currentQueue.indexWhere((item) {
              final qTitle = (item['title'] ?? '').toLowerCase();
              final dTitle = _lastTrack.toLowerCase();
              return qTitle == dTitle || qTitle.contains(dTitle) || dTitle.contains(qTitle);
            });
            
            if (playingIndex != -1 && _ytService.lastAddedTime != null) {
              final int syncThreshold = 10; // seconds
              if (DateTime.now().difference(_ytService.lastAddedTime!).inSeconds < syncThreshold) {
                // Check if playingIndex is at or after the boundary of old tracks
                final safeLength = _ytService.currentQueue.length - _ytService.recentlyAddedCount;
                if (playingIndex >= safeLength - 1) {
                  debugPrint("Throttling NEXT command to prevent endless mode bug.");
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Syncing queue with cloud... Please wait a few seconds before skipping.'), duration: Duration(seconds: 2)),
                    );
                  }
                  return;
                }
              }
            }
            await FlutterMediaController.nextTrack();
          } else if (action == 'previous') {
            await FlutterMediaController.previousTrack();
          }
        } catch (e) {
          debugPrint("Media action error: $e");
        }
      }
    });

    socket!.on('passenger_search_and_add_song', (query) async {
      debugPrint("Received passenger_search_and_add_song event: $query");
      final success = await _ytService.searchAndAddSong(query);
      if (success && mounted) {
        setState(() {
          _recentlyAdded.insert(0, query);
          if (_recentlyAdded.length > 5) _recentlyAdded.removeLast();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Resolved & Added: $query'), duration: const Duration(seconds: 2)),
        );
        if (!_queueStarted && _ytService.playlistId != null) {
          _playQueue(_ytService.playlistId!);
        }
      }
    });

    socket!.on('request_search', (data) async {
      final passengerId = data['passengerId'];
      final query = data['query'];
      final results = await _ytService.searchSongs(query);
      socket!.emit('search_results', {
        'passengerId': passengerId,
        'results': results,
      });
    });

    socket!.on('passenger_delete_song', (playlistItemId) async {
      if (_allowEditing) {
        await _ytService.deleteSong(playlistItemId);
      }
    });

    socket!.on('passenger_reorder_song', (data) async {
      if (_allowEditing) {
        await _ytService.reorderSong(data['playlistItemId'], data['videoId'], data['newPosition']);
      }
    });

    socket!.onDisconnect((_) => debugPrint('Disconnected from backend'));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    socket?.disconnect();
    _ytService.removeListener(_onYouTubeServiceUpdate);
    _dashboard.removeListener(_onDashboardUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  void _playQueue(String playlistId) {
    setState(() {
      _queueStarted = true;
      _showQrCodeOverlay = false;
    });
    final intent = AndroidIntent(
      action: 'action_view',
      data: 'https://music.youtube.com/playlist?list=$playlistId',
      package: 'com.google.android.apps.youtube.music',
    );
    intent.launch().catchError((e) {
      debugPrint("Could not launch YT Music intent: $e");
    });
    if (mounted) {
      Provider.of<DashboardProvider>(context, listen: false).setWaitingForMusic();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ytService = Provider.of<YouTubeService>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Column(
        children: [
          if (!ytService.isSignedIn)
            Padding(
              padding: const EdgeInsets.only(top: 32.0),
              child: Center(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await ytService.signIn();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("Google Sign-In failed: $e\nEnsure SHA-1 is configured in Google Cloud Console."),
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.login),
                  label: const Text("Sign in with Google"),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
              ),
            )
          else ...[
            if (!_queueStarted || _showQrCodeOverlay)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: QrImageView(
                        data: '$backendUrl/?session=$sessionId',
                        version: QrVersions.auto,
                        size: 100.0,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Session: $sessionId",
                      style: TextStyle(color: onSurface, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Scan to add songs to the collab playlist",
                      style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    if (!_queueStarted)
                      ElevatedButton.icon(
                        onPressed: ytService.playlistId != null ? () {
                          if (ytService.currentQueue.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Please add at least one song to start the collab!')),
                            );
                          } else {
                            _playQueue(ytService.playlistId!);
                          }
                        } : null,
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: const Text("START COLLAB", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                        ),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: () => setState(() => _showQrCodeOverlay = false),
                        icon: const Icon(Icons.arrow_back, size: 20),
                        label: const Text("BACK TO COLLAB", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white24,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                        ),
                      ),
                  ],
                ),
              ),
            if (_queueStarted && !_showQrCodeOverlay) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "NEXT UP",
                    style: TextStyle(
                      color: onSurface.withOpacity(0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 36, height: 36,
                          child: IconButton(
                            icon: Icon(Icons.qr_code, color: onSurface.withOpacity(0.5)),
                            onPressed: () => setState(() => _showQrCodeOverlay = true),
                            tooltip: 'Show QR Code',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 22,
                          ),
                        ),
                        SizedBox(
                          width: 36, height: 36,
                          child: IconButton(
                            icon: Icon(_allowEditing ? Icons.edit : Icons.edit_off, color: _allowEditing ? theme.colorScheme.primary : onSurface.withOpacity(0.5)),
                            onPressed: () {
                              setState(() => _allowEditing = !_allowEditing);
                              socket?.emit('update_permissions', _allowEditing);
                            },
                            tooltip: 'Allow Passenger Editing',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 22,
                          ),
                        ),
                        SizedBox(
                          width: 36, height: 36,
                          child: IconButton(
                            icon: Icon(_allowMediaControl ? Icons.play_circle_outline : Icons.not_interested, color: _allowMediaControl ? theme.colorScheme.primary : onSurface.withOpacity(0.5)),
                            onPressed: () {
                              setState(() => _allowMediaControl = !_allowMediaControl);
                              socket?.emit('update_media_permissions', _allowMediaControl);
                            },
                            tooltip: 'Allow Media Control',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 22,
                          ),
                        ),
                        if (ytService.currentQueue.isNotEmpty)
                          SizedBox(
                            width: 36, height: 36,
                            child: IconButton(
                              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: const Color(0xFF151525),
                                    title: const Text('Clear Queue?', style: TextStyle(color: Colors.white)),
                                    content: const Text('This will permanently delete all songs from the Collab playlist.', style: TextStyle(color: Colors.white70)),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context);
                                          ytService.clearPlaylist();
                                        },
                                        child: const Text('CLEAR', style: TextStyle(color: Colors.redAccent)),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              tooltip: 'Clear Queue',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              iconSize: 22,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ytService.currentQueue.isEmpty
                  ? Center(
                      child: Text(
                        "Collab playlist is empty.\nScan the QR code to add songs!",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 16),
                      ),
                    )
                  : Stack(
                      children: [
                        NotificationListener<ScrollUpdateNotification>(
                          onNotification: (notification) {
                            if (notification.dragDetails != null && !_userScrolled) {
                              setState(() => _userScrolled = true);
                            }
                            return false;
                          },
                          child: Builder(
                            builder: (context) {
                              int playingIndex = ytService.currentQueue.indexWhere((item) {
                                final qTitle = (item['title'] ?? '').toLowerCase();
                                final dTitle = _lastTrack.toLowerCase();
                                return qTitle == dTitle || qTitle.contains(dTitle) || dTitle.contains(qTitle);
                              });
                              return ListView.builder(
                                controller: _scrollController,
                                itemCount: ytService.currentQueue.length,
                                itemBuilder: (context, index) {
                                  final item = ytService.currentQueue[index];
                                  final isPlaying = index == playingIndex;
                                  
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8.0),
                                child: Container(
                                  decoration: isPlaying ? BoxDecoration(
                                    color: theme.colorScheme.primary.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 4)),
                                  ) : null,
                                  padding: isPlaying ? const EdgeInsets.only(left: 8.0, top: 4.0, bottom: 4.0) : EdgeInsets.zero,
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    leading: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        item['thumbnail'] ?? '', 
                                        width: 48, 
                                        height: 48, 
                                        fit: BoxFit.cover, 
                                        errorBuilder: (_, __, ___) => Container(
                                          width: 48, height: 48, color: Colors.grey.withOpacity(0.2), 
                                          child: const Icon(Icons.music_note)
                                        )
                                      ),
                                    ),
                                    title: Text(
                                      item['title'] ?? 'Unknown', 
                                      maxLines: 1, 
                                      overflow: TextOverflow.ellipsis, 
                                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isPlaying ? theme.colorScheme.primary : onSurface)
                                    ),
                                    subtitle: Text(
                                      item['artist'] ?? 'Unknown Artist',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 13, color: onSurface.withOpacity(0.5)),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        }),
                      ),
                      if (_userScrolled)
                          Positioned(
                            bottom: 16,
                            right: 8,
                            child: FloatingActionButton.small(
                              backgroundColor: theme.colorScheme.primary,
                              onPressed: () {
                                setState(() => _userScrolled = false);
                                _scrollToPlayingTrack();
                              },
                              child: const Icon(Icons.my_location, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
              ),
            ]
          ],
        ],
      ),
    );
  }
}
