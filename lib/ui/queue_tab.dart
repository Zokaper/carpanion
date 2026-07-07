import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/youtube_service.dart';
import '../services/collab_service.dart';

/// Thin view over [CollabService]. All collab state (socket, playback, session,
/// auto-DJ) lives in the service so it survives this widget being disposed when
/// the user navigates away. This widget only renders and forwards user actions.
class QueueTab extends StatefulWidget {
  const QueueTab({super.key});

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  // Ephemeral view state — intentionally resets to the queue view on rebuild so
  // the QR screen never shows automatically.
  bool _showQrCodeOverlay = false;
  final ScrollController _scrollController = ScrollController();
  bool _userScrolled = false;
  int _lastScrolledIndex = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int playingIndex) {
    if (playingIndex == _lastScrolledIndex) return;
    _lastScrolledIndex = playingIndex;
    if (playingIndex < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_userScrolled || !_scrollController.hasClients) return;
      final position = (playingIndex * 64.0) - 150.0;
      _scrollController.animateTo(
        position > 0 ? position : 0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ytService = context.watch<YouTubeService>();
    final collab = context.watch<CollabService>();
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    // No sign-in gate: Collab (default YT Music search + queue/playback/favorites)
    // is fully anonymous. Google sign-in is optional and only powers the "search
    // YouTube for demos" toggle — surfaced in Settings, not as a wall here.
    final playingIndex = collab.currentPlayingIndex;
    _maybeAutoScroll(playingIndex);

    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Column(
        children: [
          _buildHeader(collab, ytService, theme, onSurface),
          const SizedBox(height: 8),
          Expanded(
            child: _showQrCodeOverlay
                ? _buildQrScreen(collab, theme, onSurface)
                : _buildQueueList(collab, ytService, theme, onSurface, playingIndex),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(CollabService collab, YouTubeService ytService, ThemeData theme, Color onSurface) {
    return Row(
      children: [
        _buildCollabToggle(collab, theme),
        const SizedBox(width: 8),
        // Wrap so the icons take the remaining width and flow to a second line
        // on narrow panels instead of overflowing horizontally.
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 2,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _iconBtn(
                icon: Icons.qr_code,
                color: _showQrCodeOverlay ? theme.colorScheme.primary : onSurface.withOpacity(0.5),
                tooltip: 'Show QR Code',
                onTap: () => setState(() => _showQrCodeOverlay = !_showQrCodeOverlay),
              ),
              _iconBtn(
                icon: collab.allowEditing ? Icons.edit : Icons.edit_off,
                color: collab.allowEditing ? theme.colorScheme.primary : onSurface.withOpacity(0.5),
                tooltip: 'Allow Passenger Editing',
                onTap: () => collab.setAllowEditing(!collab.allowEditing),
              ),
              _iconBtn(
                icon: collab.allowMediaControl ? Icons.play_circle_outline : Icons.not_interested,
                color: collab.allowMediaControl ? theme.colorScheme.primary : onSurface.withOpacity(0.5),
                tooltip: 'Allow Media Control',
                onTap: () => collab.setAllowMediaControl(!collab.allowMediaControl),
              ),
              if (ytService.currentQueue.isNotEmpty)
                _iconBtn(
                  icon: Icons.delete_sweep,
                  color: Colors.redAccent,
                  tooltip: 'Clear Queue',
                  onTap: () => _confirmClearQueue(collab),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _iconBtn({required IconData icon, required Color color, required String tooltip, required VoidCallback onTap}) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        icon: Icon(icon, color: color),
        onPressed: onTap,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        iconSize: 22,
      ),
    );
  }

  /// The prominent Enable/Disable Collab control — clearly highlighted when on.
  Widget _buildCollabToggle(CollabService collab, ThemeData theme) {
    final on = collab.enabled;
    return Material(
      color: on ? theme.colorScheme.primary : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
        side: BorderSide(color: on ? theme.colorScheme.primary : Colors.white24, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () => on ? collab.disable() : collab.enable(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                on ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                size: 18,
                color: on ? Colors.white : Colors.white54,
              ),
              const SizedBox(width: 8),
              Text(
                on ? 'COLLAB ON' : 'COLLAB OFF',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: on ? Colors.white : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQrScreen(CollabService collab, ThemeData theme, Color onSurface) {
    // Centre the content when the panel is tall enough, but allow scrolling on
    // short panels so it never overflows vertically.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: collab.shareUrl,
                    version: QrVersions.auto,
                    size: 96.0,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Session: ${collab.sessionId}",
                  style: TextStyle(color: onSurface, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  "Scan to add songs to the collab playlist",
                  style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 11),
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => setState(() => _showQrCodeOverlay = false),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text("BACK", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white24,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _confirmNewSession(collab),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text("NEW SESSION", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildQueueList(CollabService collab, YouTubeService ytService, ThemeData theme, Color onSurface, int playingIndex) {
    if (ytService.currentQueue.isEmpty) {
      return Center(
        child: Text(
          "Collab playlist is empty.\nScan the QR code to add songs!",
          textAlign: TextAlign.center,
          style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 16),
        ),
      );
    }

    return Stack(
      children: [
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) {
            if (notification.dragDetails != null && !_userScrolled) {
              setState(() => _userScrolled = true);
            }
            return false;
          },
          child: ListView.builder(
            controller: _scrollController,
            itemCount: ytService.currentQueue.length,
            itemBuilder: (context, index) {
              final item = ytService.currentQueue[index];
              final isPlaying = index == playingIndex;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Container(
                  decoration: isPlaying
                      ? BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 4)),
                        )
                      : null,
                  padding: isPlaying ? const EdgeInsets.only(left: 8.0, top: 4.0, bottom: 4.0) : EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    onTap: () => collab.playAt(index),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        item['thumbnail'] ?? '',
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 48,
                          height: 48,
                          color: Colors.grey.withOpacity(0.2),
                          child: const Icon(Icons.music_note),
                        ),
                      ),
                    ),
                    title: Text(
                      item['title'] ?? 'Unknown',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isPlaying ? theme.colorScheme.primary : onSurface,
                      ),
                    ),
                    subtitle: Text(
                      item['artist'] ?? 'Unknown Artist',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: onSurface.withOpacity(0.5)),
                    ),
                    trailing: isPlaying
                        ? Icon(Icons.equalizer, color: theme.colorScheme.primary, size: 20)
                        : Icon(Icons.play_arrow, color: onSurface.withOpacity(0.3), size: 20),
                  ),
                ),
              );
            },
          ),
        ),
        if (_userScrolled)
          Positioned(
            bottom: 16,
            right: 8,
            child: FloatingActionButton.small(
              backgroundColor: theme.colorScheme.primary,
              onPressed: () {
                setState(() => _userScrolled = false);
                _lastScrolledIndex = -1;
                _maybeAutoScroll(playingIndex);
              },
              child: const Icon(Icons.my_location, color: Colors.white),
            ),
          ),
      ],
    );
  }

  void _confirmClearQueue(CollabService collab) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF151525),
        title: const Text('Clear Queue?', style: TextStyle(color: Colors.white)),
        content: const Text('This empties the Collab playlist but keeps the same session.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('CANCEL')),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              collab.clearQueue();
            },
            child: const Text('CLEAR', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _confirmNewSession(CollabService collab) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF151525),
        title: const Text('New Session?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This generates a new session code and clears the playlist. Passengers will need to re-scan the new QR code.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('CANCEL')),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              collab.newSession();
            },
            child: const Text('NEW SESSION', style: TextStyle(color: Colors.orangeAccent)),
          ),
        ],
      ),
    );
  }
}
