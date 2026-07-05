import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:android_intent_plus/android_intent.dart';
import '../services/youtube_service.dart';

class QueueTab extends StatefulWidget {
  const QueueTab({super.key});

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  final String backendUrl = "https://carpanion.onrender.com";
  late String sessionId;
  IO.Socket? socket;
  final List<String> _recentlyAdded = [];
  bool _queueStarted = false;
  bool _showQrCodeOverlay = false;
  bool _allowEditing = false;
  late YouTubeService _ytService;

  @override
  void initState() {
    super.initState();
    sessionId = _generateSessionId();
    _ytService = Provider.of<YouTubeService>(context, listen: false);
    _ytService.addListener(_onYouTubeServiceUpdate);
    _connectSocket();
  }

  void _onYouTubeServiceUpdate() {
    if (socket?.connected == true) {
      socket!.emit('update_queue', _ytService.currentQueue);
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
        }
      }
    });

    socket!.on('request_queue', (_) {
      socket!.emit('update_queue', _ytService.currentQueue);
    });

    socket!.on('request_permissions', (_) {
      socket!.emit('update_permissions', _allowEditing);
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
    socket?.disconnect();
    _ytService.removeListener(_onYouTubeServiceUpdate);
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
  }

  @override
  Widget build(BuildContext context) {
    final ytService = Provider.of<YouTubeService>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 8),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: Icon(Icons.qr_code, color: _showQrCodeOverlay ? theme.colorScheme.primary : onSurface.withOpacity(0.5)),
                    onPressed: () => setState(() => _showQrCodeOverlay = !_showQrCodeOverlay),
                    tooltip: 'Toggle QR Code',
                  ),
                  IconButton(
                    icon: Icon(_allowEditing ? Icons.edit : Icons.edit_off, color: _allowEditing ? theme.colorScheme.primary : onSurface.withOpacity(0.5)),
                    onPressed: () {
                      setState(() => _allowEditing = !_allowEditing);
                      socket?.emit('update_permissions', _allowEditing);
                    },
                    tooltip: 'Allow Passenger Editing',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (!_queueStarted || _showQrCodeOverlay) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: '$backendUrl/?session=$sessionId',
                    version: QrVersions.auto,
                    size: 160.0,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "Session: $sessionId",
                  style: TextStyle(
                    color: onSurface,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Scan to add songs to the queue",
                  style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 14),
                ),
                const SizedBox(height: 24),
                if (!_queueStarted)
                  ElevatedButton.icon(
                    onPressed: ytService.playlistId != null 
                        ? () => _playQueue(ytService.playlistId!) 
                        : null,
                    icon: const Icon(Icons.play_arrow, size: 28),
                    label: const Text("START QUEUE", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
              ],
              if (_queueStarted && !_showQrCodeOverlay) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "NEXT UP",
                    style: TextStyle(
                      color: onSurface.withOpacity(0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ...ytService.currentQueue.map((item) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          item['thumbnail'] ?? '', 
                          width: 56, 
                          height: 56, 
                          fit: BoxFit.cover, 
                          errorBuilder: (_, __, ___) => Container(
                            width: 56, height: 56, color: Colors.grey.withOpacity(0.2), 
                            child: const Icon(Icons.music_note)
                          )
                        ),
                      ),
                      title: Text(
                        item['title'] ?? 'Unknown', 
                        maxLines: 1, 
                        overflow: TextOverflow.ellipsis, 
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: onSurface)
                      ),
                      subtitle: Text(
                        item['artist'] ?? 'Unknown Artist',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: onSurface.withOpacity(0.5)),
                      ),
                    ),
                  );
                }),
                if (ytService.currentQueue.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Center(
                      child: Text(
                        "Queue is empty.\nScan the QR code to add songs!",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 16),
                      ),
                    ),
                  )
              ],
            ]
          ],
        ),
      ),
    );
  }
}
