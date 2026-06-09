import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NotificationsTab extends StatefulWidget {
  const NotificationsTab({super.key});

  @override
  State<NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<NotificationsTab> {
  static const platform = MethodChannel('com.example.car_dashboard/system');
  List<Map<dynamic, dynamic>> _notifications = [];
  Timer? _timer;
  
  final Map<String, MemoryImage> _iconCache = {};
  final Set<String> _expandedKeys = {};

  @override
  void initState() {
    super.initState();
    _fetchNotifications();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchNotifications());
  }

  Future<void> _fetchNotifications() async {
    try {
      final List<dynamic>? result = await platform.invokeMethod('getActiveNotifications');
      if (result != null && mounted) {
        final notifs = result.cast<Map<dynamic, dynamic>>();
        
        // Cache icons to prevent flickering
        for (final notif in notifs) {
          final key = notif['key']?.toString();
          if (key != null && !_iconCache.containsKey(key)) {
            final iconBytes = notif['icon'] as Uint8List?;
            if (iconBytes != null) {
              _iconCache[key] = MemoryImage(iconBytes);
            }
          }
        }

        setState(() {
          _notifications = notifs;
        });
      }
    } catch (e) {
      debugPrint("Failed to fetch notifications: $e");
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatTime(String? timestampStr) {
    if (timestampStr == null || timestampStr.isEmpty) return '';
    try {
      final ms = int.tryParse(timestampStr);
      if (ms == null) return '';
      final date = DateTime.fromMillisecondsSinceEpoch(ms);
      int hour = date.hour;
      final ampm = hour >= 12 ? 'PM' : 'AM';
      if (hour > 12) hour -= 12;
      if (hour == 0) hour = 12;
      final min = date.minute.toString().padLeft(2, '0');
      return "$hour:$min $ampm";
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
          child: Text(
            "ALERTS & NOTIFICATIONS",
            style: TextStyle(
              color: onSurface.withOpacity(0.6),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
        ),
        Expanded(
          child: _notifications.isEmpty
              ? Center(
                  child: Text("No new notifications.", style: TextStyle(color: onSurface.withOpacity(0.54))),
                )
              : ListView.builder(
                  itemCount: _notifications.length,
                  itemBuilder: (context, index) {
                    final notif = _notifications[index];
                    final key = notif['key']?.toString() ?? '';
                    final title = notif['title']?.toString() ?? '';
                    final text = notif['text']?.toString() ?? '';
                    final appName = notif['appName']?.toString() ?? '';
                    final subText = notif['subText']?.toString() ?? '';
                    final pkg = notif['package']?.toString() ?? '';
                    final timeStr = _formatTime(notif['postTime']?.toString());
                    
                    final isExpanded = _expandedKeys.contains(key);
                    final imageProvider = _iconCache[key];
                    
                    String topText = appName.isNotEmpty ? appName : pkg.split('.').last;
                    if (subText.isNotEmpty) {
                      topText += " • $subText";
                    }
                    
                    return GestureDetector(
                      onTap: () {
                         if (_expandedKeys.contains(key)) {
                            setState(() { _expandedKeys.remove(key); });
                         } else {
                            setState(() { _expandedKeys.add(key); });
                         }
                      },
                      onDoubleTap: () {
                         platform.invokeMethod('openNotification', {'key': key});
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6.0),
                        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
                        decoration: BoxDecoration(
                          color: onSurface.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: onSurface.withOpacity(0.02)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              padding: imageProvider == null ? const EdgeInsets.all(6) : null,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondary.withOpacity(0.2),
                                shape: BoxShape.circle,
                              ),
                              clipBehavior: Clip.hardEdge,
                              child: imageProvider != null 
                                ? Image(image: imageProvider, fit: BoxFit.cover)
                                : Icon(Icons.notifications_active, color: theme.colorScheme.secondary, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(child: Text(topText.toUpperCase(), style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 9, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                      Text(timeStr, style: TextStyle(color: onSurface.withOpacity(0.54), fontSize: 10)),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  if (title.isNotEmpty)
                                    Text(title, style: TextStyle(color: onSurface, fontSize: 13, fontWeight: FontWeight.bold), maxLines: isExpanded ? null : 1, overflow: isExpanded ? null : TextOverflow.ellipsis),
                                  const SizedBox(height: 1),
                                  if (text.isNotEmpty)
                                    Text(text, style: TextStyle(color: onSurface.withOpacity(0.8), fontSize: 12), maxLines: isExpanded ? null : 2, overflow: isExpanded ? null : TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
