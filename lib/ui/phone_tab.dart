import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:call_log/call_log.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../main.dart';

class PhoneTab extends StatefulWidget {
  const PhoneTab({super.key});

  @override
  State<PhoneTab> createState() => _PhoneTabState();
}

class _PhoneTabState extends State<PhoneTab> {
  static List<Contact> _cachedFavorites = [];
  static List<CallLogEntry> _cachedRecents = [];
  static bool _hasLoaded = false;

  List<Contact> _favorites = _cachedFavorites;
  List<CallLogEntry> _recents = _cachedRecents;
  bool _isLoading = !_hasLoaded;

  @override
  void initState() {
    super.initState();
    if (!_hasLoaded) {
      _fetchPhoneData();
    }
  }

  Future<void> _fetchPhoneData() async {
    try {
      // Fetch Call Logs
      Iterable<CallLogEntry> entries = [];
      try {
        entries = await CallLog.get();
      } catch (e) {
        debugPrint("CallLog error: $e");
      }
      
      // Fetch Contacts
      List<Contact> contacts = [];
      final status = await FlutterContacts.permissions.request(PermissionType.read);
      if (status == PermissionStatus.granted) {
        contacts = await FlutterContacts.getAll(properties: ContactProperties.all);
      }

      if (mounted) {
        setState(() {
          _cachedRecents = entries.take(4).toList();
          // Filter starred contacts, or just take some if none are starred
          var starred = contacts.where((c) => c.android?.isFavorite == true).toList();
          if (starred.isEmpty && contacts.isNotEmpty) {
            starred = contacts.take(10).toList();
          }
          _cachedFavorites = starred;
          _hasLoaded = true;
          
          _recents = _cachedRecents;
          _favorites = _cachedFavorites;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _makeCall(String number) async {
    if (!mounted) return;
    final provider = Provider.of<DashboardProvider>(context, listen: false);
    provider.makeCall(number);
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    if (!provider.hasPhonePermissions) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.phone_locked_rounded, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              const Text(
                "Phone permissions are required to display contacts and manage calls directly within the dashboard.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: provider.requestPhonePermissions,
                icon: const Icon(Icons.settings_phone),
                label: const Text("GRANT PERMISSION"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Removing call screen override so the tab just displays recents/favorites.

    if (!_hasLoaded && !_isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _isLoading = true;
        });
        _fetchPhoneData();
      });
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Recents
          if (_recents.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
              child: Text(
                "RECENT CALLS",
                style: TextStyle(
                  color: onSurface.withOpacity(0.6),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            Column(
              children: [
                for (int i = 0; i < _recents.length; i += 2)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: _RecentCallChip(
                            title: _recents[i].name?.isNotEmpty == true ? _recents[i].name! : (_recents[i].number ?? 'Unknown'),
                            subtitle: _recents[i].number ?? '',
                            onTap: () => _makeCall(_recents[i].number ?? ''),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (i + 1 < _recents.length)
                          Expanded(
                            child: _RecentCallChip(
                              title: _recents[i + 1].name?.isNotEmpty == true ? _recents[i + 1].name! : (_recents[i + 1].number ?? 'Unknown'),
                              subtitle: _recents[i + 1].number ?? '',
                              onTap: () => _makeCall(_recents[i + 1].number ?? ''),
                            ),
                          )
                        else
                          const Expanded(child: SizedBox.shrink()),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
          ],

          // Favorites
          Padding(
            padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
            child: Text(
              "FAVORITES",
              style: TextStyle(
                color: onSurface.withOpacity(0.6),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
          if (_favorites.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text("No favorites found.", style: TextStyle(color: onSurface.withOpacity(0.54))),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _favorites.length,
              itemBuilder: (context, index) {
                final contact = _favorites[index];
                final phone = contact.phones.isNotEmpty ? contact.phones.first.number : '';
                return _FavoriteCard(
                  title: contact.displayName ?? 'Unknown',
                  subtitle: phone,
                  onTap: () {
                    if (phone.isNotEmpty) _makeCall(phone);
                  },
                );
              },
            ),
        ],
      ),
    );
  }

// Helper methods moved to CallScreenWidget
}

class CallScreenWidget extends StatelessWidget {
  const CallScreenWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final state = provider.callState;
    final isRinging = state == 'RINGING';
    final isDialing = state == 'DIALING';
    final isConnecting = state == 'CONNECTING';
    final isActive = state == 'ACTIVE';

    final durationStr = _formatDuration(provider.callDurationSeconds);

    String pillText = "ACTIVE CALL";
    Color pillColor = theme.colorScheme.primary;
    if (isRinging) {
      pillText = "INCOMING CALL";
      pillColor = Colors.amber;
    } else if (isDialing) {
      pillText = "DIALING...";
      pillColor = Colors.lightBlueAccent;
    } else if (isConnecting) {
      pillText = "CONNECTING...";
      pillColor = Colors.lightBlueAccent;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: onSurface.withOpacity(0.05)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: pillColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: pillColor.withOpacity(0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: pillColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  pillText,
                  style: TextStyle(
                    color: pillColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(flex: 2),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary,
                  theme.colorScheme.secondary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Text(
                _getInitials(provider.callName),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const Spacer(flex: 1),
          Text(
            provider.callName.isNotEmpty ? provider.callName : "Unknown Caller",
            style: TextStyle(
              color: onSurface,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (provider.callNumber.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              provider.callNumber,
              style: TextStyle(
                color: onSurface.withOpacity(0.5),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (isActive) ...[
            const Spacer(flex: 1),
            Text(
              durationStr,
              style: TextStyle(
                color: onSurface,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const Spacer(flex: 2),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 32,
            runSpacing: 16,
            children: [
              if (isRinging) ...[
                _buildCallActionButton(
                  icon: Icons.call,
                  color: Colors.greenAccent,
                  label: "Answer",
                  onPressed: provider.answerCall,
                ),
                _buildCallActionButton(
                  icon: Icons.call_end,
                  color: Colors.redAccent,
                  label: "Decline",
                  onPressed: provider.endCall,
                ),
              ] else ...[
                _buildCallActionButton(
                  icon: provider.isMuted ? Icons.mic_off : Icons.mic,
                  color: provider.isMuted ? Colors.amber : onSurface.withOpacity(0.7),
                  label: provider.isMuted ? "Unmute" : "Mute",
                  onPressed: provider.toggleMute,
                ),
                _buildCallActionButton(
                  icon: Icons.call_end,
                  color: Colors.redAccent,
                  label: "End Call",
                  size: 64,
                  iconSize: 32,
                  onPressed: provider.endCall,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return "$minutes:$secs";
  }

  String _getInitials(String name) {
    if (name.isEmpty) return "?";
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return parts[0][0].toUpperCase();
  }

  Widget _buildCallActionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onPressed,
    double size = 56,
    double iconSize = 24,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              shape: BoxShape.circle,
              border: Border.all(color: color.withOpacity(0.5), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.1),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: color,
              size: iconSize,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _RecentCallChip extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RecentCallChip({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: onSurface.withOpacity(0.02)),
        ),
        child: Row(
          children: [
            Icon(Icons.history, color: theme.colorScheme.primary, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, style: TextStyle(color: onSurface, fontSize: 11, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(subtitle, style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 9), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _FavoriteCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10.0),
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withOpacity(0.8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: onSurface.withOpacity(0.05)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person, color: theme.colorScheme.primary, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(title, style: TextStyle(color: onSurface, fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.call, color: Colors.greenAccent.withOpacity(0.9), size: 24),
            ),
          ],
        ),
      ),
    );
  }
}
