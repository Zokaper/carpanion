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

  String? _trackedChatId;
  String? _trackedChatTitle;
  String? _trackedChatAppName;
  final ValueNotifier<List<Map<String, String>>> _trackedMessagesNotifier = ValueNotifier([]);


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

        if (_trackedChatId != null) {
          final newMessages = List<Map<String, String>>.from(_trackedMessagesNotifier.value);
          bool updated = false;

          for (final notif in notifs) {
            final pkg = notif['package']?.toString() ?? '';
            final title = notif['title']?.toString() ?? '';
            final chatId = '$pkg|$title';

            if (chatId == _trackedChatId) {
              final text = notif['text']?.toString() ?? '';
              final timeStr = _formatTime(notif['postTime']?.toString());
              
              bool isNew = true;
              for (final msg in newMessages) {
                if (msg['rawText'] == text && msg['time'] == timeStr) {
                  isNew = false;
                  break;
                }
              }

              if (isNew && text.isNotEmpty) {
                String sender = title;
                String messageText = text;
                if (text.contains(': ')) {
                  final parts = text.split(': ');
                  sender = parts[0];
                  messageText = parts.sublist(1).join(': ');
                }

                newMessages.add({
                  'sender': sender,
                  'text': messageText,
                  'time': timeStr,
                  'rawText': text,
                });
                updated = true;
              }
            }
          }

          if (updated) {
            _trackedMessagesNotifier.value = newMessages;
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

  void _startTracking(String pkg, String title, String appName) {
    setState(() {
      _trackedChatId = '$pkg|$title';
      _trackedChatTitle = title;
      _trackedChatAppName = appName;
    });
    
    final initialMessages = <Map<String, String>>[];
    for (final notif in _notifications) {
      final nPkg = notif['package']?.toString() ?? '';
      final nTitle = notif['title']?.toString() ?? '';
      if ('$nPkg|$nTitle' == _trackedChatId) {
        final text = notif['text']?.toString() ?? '';
        final timeStr = _formatTime(notif['postTime']?.toString());
        if (text.isNotEmpty) {
          String sender = title;
          String messageText = text;
          if (text.contains(': ')) {
            final parts = text.split(': ');
            sender = parts[0];
            messageText = parts.sublist(1).join(': ');
          }
          // Avoid duplicates
          bool isNew = true;
          for (final msg in initialMessages) {
            if (msg['rawText'] == text && msg['time'] == timeStr) {
              isNew = false;
              break;
            }
          }
          if (isNew) {
            initialMessages.add({
              'sender': sender,
              'text': messageText,
              'time': timeStr,
              'rawText': text,
            });
          }
        }
      }
    }
    
    _trackedMessagesNotifier.value = initialMessages;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    if (_trackedChatId != null) {
      return TrackedChatView(
        title: _trackedChatTitle ?? '',
        appName: _trackedChatAppName ?? '',
        messagesNotifier: _trackedMessagesNotifier,
        onBack: () {
          setState(() {
            _trackedChatId = null;
          });
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "ALERTS & NOTIFICATIONS",
                style: TextStyle(
                  color: onSurface.withOpacity(0.6),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              if (_notifications.isNotEmpty)
                GestureDetector(
                  onTap: () async {
                    try {
                      await platform.invokeMethod('clearAllNotifications');
                      setState(() {
                        _notifications.clear();
                        _expandedKeys.clear();
                      });
                    } catch (e) {
                      debugPrint("Clear all failed: $e");
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Text(
                      "CLEAR ALL",
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
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
                    
                    return Dismissible(
                      key: ValueKey(key),
                      direction: DismissDirection.horizontal,
                      onDismissed: (direction) {
                        platform.invokeMethod('clearNotification', {'key': key});
                        setState(() {
                          _notifications.removeAt(index);
                          _expandedKeys.remove(key);
                        });
                      },
                      background: Container(
                        margin: const EdgeInsets.only(bottom: 6.0),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20.0),
                        child: const Icon(Icons.delete_outline, color: Colors.white),
                      ),
                      child: GestureDetector(
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
                                  if (isExpanded) ...[
                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: OutlinedButton(
                                        onPressed: () => _startTracking(pkg, title, appName),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                        child: Text(
                                          "TRACK",
                                          style: TextStyle(
                                            color: theme.colorScheme.primary,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
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

class TrackedChatView extends StatelessWidget {
  final String title;
  final String appName;
  final ValueNotifier<List<Map<String, String>>> messagesNotifier;
  final VoidCallback onBack;

  const TrackedChatView({
    super.key,
    required this.title,
    required this.appName,
    required this.messagesNotifier,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Column(
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "Tracking via $appName",
                    style: TextStyle(fontSize: 11, color: onSurface.withOpacity(0.6)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Divider(),
        Expanded(
          child: ValueListenableBuilder<List<Map<String, String>>>(
            valueListenable: messagesNotifier,
            builder: (context, messages, _) {
              if (messages.isEmpty) {
                return Center(
                  child: Text(
                    "No messages tracked yet.",
                    style: TextStyle(color: onSurface.withOpacity(0.5)),
                  ),
                );
              }

                  return ListView.builder(
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg['sender'] == 'Me'; // Simple heuristic
                      
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            if (!isMe)
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0, bottom: 4.0),
                                child: Text(
                                  msg['sender'] ?? '',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: onSurface.withOpacity(0.6),
                                  ),
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isMe 
                                    ? theme.colorScheme.primary.withOpacity(0.8)
                                    : onSurface.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(16).copyWith(
                                  bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
                                  bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
                                ),
                              ),
                              child: Text(
                                msg['text'] ?? '',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isMe ? theme.colorScheme.onPrimary : onSurface,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0, left: 8.0, right: 8.0),
                              child: Text(
                                msg['time'] ?? '',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: onSurface.withOpacity(0.4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
              },
            ),
        ),
      ],
    );
  }
}
