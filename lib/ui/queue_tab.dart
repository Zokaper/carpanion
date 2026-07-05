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
  bool _showQrCode = true;
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Switch(
                        value: _showQrCode,
                        onChanged: (val) => setState(() => _showQrCode = val),
                        activeColor: theme.colorScheme.primary,
                      ),
                      Text("Show QR", style: TextStyle(fontSize: 10)),
                    ],
                  ),
                  Row(
                    children: [
                      Switch(
                        value: _allowEditing,
                        onChanged: (val) {
                          setState(() => _allowEditing = val);
                          socket?.emit('update_permissions', val);
                        },
                        activeColor: theme.colorScheme.primary,
                      ),
                      Text("Allow Edit", style: TextStyle(fontSize: 10)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_showQrCode) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: '$backendUrl/?session=$sessionId',
                    version: QrVersions.auto,
                    size: 120.0,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Session: $sessionId",
                  style: TextStyle(
                    color: onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Scan to add songs to the queue",
                  style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 12),
                ),
              ] else ...[
                Text(
                  "NEXT UP",
                  style: TextStyle(
                    color: onSurface.withOpacity(0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                ...ytService.currentQueue.map((item) {
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(item['thumbnail'] ?? '', width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_note)),
                    ),
                    title: Text(item['title'] ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12)),
                  );
                }),
              ],
              const SizedBox(height: 16),
              if (_recentlyAdded.isNotEmpty) ...[
                Text(
                  "Recently Added",
                  style: TextStyle(
                    color: onSurface.withOpacity(0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                ..._recentlyAdded.map((song) => Text(
                  song,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: onSurface, fontSize: 12),
                )),
                const SizedBox(height: 16),
              ],
              ElevatedButton.icon(
                onPressed: ytService.playlistId != null 
                    ? () => _playQueue(ytService.playlistId!) 
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text("PLAY QUEUE"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
