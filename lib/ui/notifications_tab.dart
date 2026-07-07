import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  String _lastNotifSignature = '';

  final Map<String, MemoryImage> _iconCache = {};
  final Set<String> _expandedKeys = {};
  final Set<String> _expandedApps = {};

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
        
        // Cache icons to prevent flickering; track current keys for pruning.
        final currentKeys = <String>{};
        for (final notif in notifs) {
          final key = notif['key']?.toString();
          if (key != null) {
            currentKeys.add(key);
            if (!_iconCache.containsKey(key)) {
              final iconBytes = notif['icon'] as Uint8List?;
              if (iconBytes != null) {
                _iconCache[key] = MemoryImage(iconBytes);
              }
            }
          }
        }
        // Drop cached icons for notifications that are no longer present.
        _iconCache.removeWhere((k, _) => !currentKeys.contains(k));

        if (_trackedChatId != null) {
          final newMessages = List<Map<String, String>>.from(_trackedMessagesNotifier.value);
          bool updated = false;

          for (final notif in notifs) {
            final pkg = notif['package']?.toString() ?? '';
            final rawTitle = notif['title']?.toString() ?? '';
            final rawText = notif['text']?.toString() ?? '';
            
            final key = notif['key']?.toString() ?? '';
            String chatTitle = rawTitle;
            if (rawTitle.contains(': ')) {
              chatTitle = rawTitle.split(': ')[0];
            }

            if (key == _trackedChatId) {
              final extracted = _extractMessages(notif, chatTitle);
              for (final ext in extracted) {
                 bool isNew = true;
                 for (final msg in newMessages) {
                   if (msg['rawText'] == ext['rawText'] && msg['time'] == ext['time']) {
                     isNew = false;
                     break;
                   }
                 }
                 if (isNew) {
                   newMessages.add(ext);
                   updated = true;
                 }
              }
            }
          }

          if (updated) {
            _trackedMessagesNotifier.value = newMessages;
          }
        }

        // Only rebuild the (grouped) list when the visible set actually changed,
        // instead of every 3s tick.
        final signature = notifs
            .map((n) => '${n['key']}:${n['postTime']}:${n['title']}:${n['text']}')
            .join('|');
        if (signature != _lastNotifSignature) {
          _lastNotifSignature = signature;
          setState(() {
            _notifications = notifs;
          });
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch notifications: $e");
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _trackedMessagesNotifier.dispose();
    super.dispose();
  }

  List<Map<String, String>> _extractMessages(Map notif, String chatTitle) {
    final results = <Map<String, String>>[];
    final timeStr = _formatTime(notif['postTime']?.toString());
    final rawTitle = notif['title']?.toString() ?? '';
    final rawText = notif['text']?.toString() ?? '';
    final messagesArray = notif['messages'] as List<dynamic>?;

    if (messagesArray != null && messagesArray.isNotEmpty) {
      for (final m in messagesArray) {
        final mMap = m as Map<dynamic, dynamic>;
        final mText = mMap['text']?.toString() ?? '';
        final mSender = mMap['sender']?.toString() ?? '';
        
        String finalSender = mSender.isNotEmpty ? mSender : chatTitle;
        String finalText = mText;
        
        if (mSender.isEmpty && mText.contains(': ')) {
          final parts = mText.split(': ');
          finalSender = parts[0];
          finalText = parts.sublist(1).join(': ');
        }
        
        String mTimeStr = '';
        if (mMap['time'] != null && mMap['time'].toString().isNotEmpty && mMap['time'].toString() != '0') {
           mTimeStr = _formatTime(mMap['time'].toString());
        }
        if (mTimeStr.isEmpty) mTimeStr = timeStr;
        
        results.add({
          'sender': finalSender,
          'text': finalText,
          'time': mTimeStr,
          'rawText': mText,
        });
      }
    } else if (rawText.isNotEmpty) {
      String finalSender = rawTitle;
      String finalText = rawText;
      
      if (rawTitle.contains(': ')) {
        finalSender = rawTitle.split(': ').sublist(1).join(': ');
      } else if (rawText.contains(': ')) {
        final parts = rawText.split(': ');
        finalSender = parts[0];
        finalText = parts.sublist(1).join(': ');
      }
      
      results.add({
        'sender': finalSender,
        'text': finalText,
        'time': timeStr,
        'rawText': rawText,
      });
    }
    return results;
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

  void _startTracking(String key, String rawTitle, String appName) {
    String chatTitle = rawTitle;
    if (rawTitle.contains(': ')) {
      chatTitle = rawTitle.split(': ')[0];
    }

    setState(() {
      _trackedChatId = key;
      _trackedChatTitle = chatTitle;
      _trackedChatAppName = appName;
    });
    
    final initialMessages = <Map<String, String>>[];
    for (final notif in _notifications) {
      final nKey = notif['key']?.toString() ?? '';
      
      final nTitle = notif['title']?.toString() ?? '';
      String nChatTitle = nTitle;
      if (nTitle.contains(': ')) {
        nChatTitle = nTitle.split(': ')[0];
      }

      if (nKey == _trackedChatId) {
        final extracted = _extractMessages(notif, nChatTitle);
        for (final ext in extracted) {
           bool isNew = true;
           for (final msg in initialMessages) {
             if (msg['rawText'] == ext['rawText'] && msg['time'] == ext['time']) {
               isNew = false;
               break;
             }
           }
           if (isNew) {
             initialMessages.add(ext);
           }
        }
      }
    }
    
    _trackedMessagesNotifier.value = initialMessages;
  }

  bool _isConversation(Map notif) {
    final title = notif['title']?.toString() ?? '';
    final text = notif['text']?.toString() ?? '';
    final pkg = notif['package']?.toString().toLowerCase() ?? '';
    
    if (title.contains(': ') || text.contains(': ')) return true;
    if (pkg.contains('whatsapp') || pkg.contains('messaging') || pkg.contains('telegram') || pkg.contains('discord') || pkg.contains('messenger') || pkg.contains('sms') || pkg.contains('snapchat')) {
      return true;
    }
    return false;
  }

  Widget _buildNotificationItem(Map notif, ThemeData theme, Color onSurface, {bool hideApp = false}) {
    final key = notif['key']?.toString() ?? '';
    final rawTitle = notif['title']?.toString() ?? '';
    final rawText = notif['text']?.toString() ?? '';
    final appName = notif['appName']?.toString() ?? '';
    final subText = notif['subText']?.toString() ?? '';
    final pkg = notif['package']?.toString() ?? '';
    final timeStr = _formatTime(notif['postTime']?.toString());
    
    String displayTitle = rawTitle;
    String displayText = rawText;
    if (rawTitle.contains(': ')) {
      displayTitle = rawTitle.split(': ')[0];
      String sender = rawTitle.split(': ').sublist(1).join(': ');
      displayText = "$sender: $rawText";
    }

    final isExpanded = _expandedKeys.contains(key);
    final imageProvider = _iconCache[key];
    
    String topText = appName.isNotEmpty ? appName : pkg.split('.').last;
    if (subText.isNotEmpty) {
      topText += " • $subText";
    }
    if (hideApp) {
      topText = subText;
    }
    
    return Dismissible(
      key: ValueKey(key),
      direction: DismissDirection.endToStart,
      onDismissed: (direction) {
        platform.invokeMethod('clearNotification', {'key': key}).catchError((e) => debugPrint("clearNotification failed: $e"));
        setState(() {
          _notifications.removeWhere((n) => n['key'] == key);
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
           platform.invokeMethod('openNotification', {'key': key}).catchError((e) => debugPrint("openNotification failed: $e"));
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
                      if (topText.isNotEmpty)
                        Expanded(child: Text(topText.toUpperCase(), style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 9, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis))
                      else
                        const Spacer(),
                      Text(timeStr, style: TextStyle(color: onSurface.withOpacity(0.54), fontSize: 10)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (displayTitle.isNotEmpty)
                    Text(displayTitle, style: TextStyle(color: onSurface, fontSize: 13, fontWeight: FontWeight.bold), maxLines: isExpanded ? null : 1, overflow: isExpanded ? null : TextOverflow.ellipsis),
                  const SizedBox(height: 1),
                  if (displayText.isNotEmpty)
                    Text(displayText, style: TextStyle(color: onSurface.withOpacity(0.8), fontSize: 12), maxLines: isExpanded ? null : 2, overflow: isExpanded ? null : TextOverflow.ellipsis),
                  if (isExpanded) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(
                        onPressed: () => _startTracking(key, rawTitle, appName),
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
  }

  Widget _buildAppGroup(String appName, List<Map> notifs, bool isConversation, ThemeData theme, Color onSurface) {
    final groupId = isConversation ? 'conv_$appName' : 'gen_$appName';
    final isExpanded = _expandedApps.contains(groupId);
    final count = notifs.length;
    
    MemoryImage? appIcon;
    for (final n in notifs) {
      final key = n['key']?.toString();
      if (key != null && _iconCache.containsKey(key)) {
         appIcon = _iconCache[key];
         break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Dismissible(
          key: ValueKey('group_$groupId'),
          direction: DismissDirection.endToStart,
          onDismissed: (direction) {
            for (final n in notifs) {
              final k = n['key']?.toString();
              if (k != null) {
                platform.invokeMethod('clearNotification', {'key': k}).catchError((e) => debugPrint("clearNotification failed: $e"));
              }
            }
            setState(() {
              final keysToRemove = notifs.map((n) => n['key']?.toString()).toSet();
              _notifications.removeWhere((n) => keysToRemove.contains(n['key']?.toString()));
              _expandedApps.remove(groupId);
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
              setState(() {
                if (isExpanded) {
                  _expandedApps.remove(groupId);
                } else {
                  _expandedApps.add(groupId);
                }
              });
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 6.0),
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: onSurface.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  padding: appIcon == null ? const EdgeInsets.all(4) : null,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondary.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: appIcon != null 
                    ? Image(image: appIcon, fit: BoxFit.cover)
                    : Icon(Icons.apps, color: theme.colorScheme.secondary, size: 14),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    appName.toUpperCase(), 
                    style: TextStyle(color: onSurface, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count.toString(),
                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: onSurface.withOpacity(0.5),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 12.0, top: 2.0, bottom: 6.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: notifs.map((n) => _buildNotificationItem(n, theme, onSurface, hideApp: true)).toList(),
            ),
          ),
      ],
    );
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

    final conversations = _notifications.where((n) => _isConversation(n)).toList();
    final generalNotifs = _notifications.where((n) => !_isConversation(n)).toList();

    Map<String, List<Map>> groupedConversations = {};
    for (var n in conversations) {
      String app = n['appName']?.toString() ?? '';
      if (app.isEmpty) app = (n['package']?.toString() ?? '').split('.').last;
      groupedConversations.putIfAbsent(app, () => []).add(n);
    }

    Map<String, List<Map>> groupedGeneral = {};
    for (var n in generalNotifs) {
      String app = n['appName']?.toString() ?? '';
      if (app.isEmpty) app = (n['package']?.toString() ?? '').split('.').last;
      groupedGeneral.putIfAbsent(app, () => []).add(n);
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
              : ListView(
                  children: [
                    if (groupedConversations.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 4.0, bottom: 8.0, top: 4.0),
                        child: Text("CONVERSATIONS", style: TextStyle(color: theme.colorScheme.primary, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      ),
                      ...groupedConversations.entries.map((entry) {
                        if (entry.value.length == 1) {
                          return _buildNotificationItem(entry.value.first, theme, onSurface);
                        }
                        return _buildAppGroup(entry.key, entry.value, true, theme, onSurface);
                      }),
                    ],
                    if (groupedGeneral.isNotEmpty) ...[
                      Padding(
                        padding: EdgeInsets.only(left: 4.0, bottom: 8.0, top: groupedConversations.isNotEmpty ? 16.0 : 4.0),
                        child: Text("GENERAL", style: TextStyle(color: theme.colorScheme.primary, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      ),
                      ...groupedGeneral.entries.map((entry) {
                        if (entry.value.length == 1) {
                          return _buildNotificationItem(entry.value.first, theme, onSurface);
                        }
                        return _buildAppGroup(entry.key, entry.value, false, theme, onSurface);
                      }),
                    ],
                  ],
                ),
        ),
      ],
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

class _AutoScrollTextState extends State<AutoScrollText> {
  late ScrollController _scrollController;
  bool _isScrolling = true;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scroll();
    });
  }

  void _scroll() async {
    await Future.delayed(const Duration(seconds: 1));
    while (_isScrolling && mounted) {
      if (_scrollController.hasClients) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        if (maxScroll > 0) {
          final duration = Duration(milliseconds: (maxScroll * 30).toInt());
          
          await _scrollController.animateTo(
            maxScroll,
            duration: duration,
            curve: Curves.linear,
          );
          
          if (!mounted || !_isScrolling) break;
          
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted || !_isScrolling) break;
          
          _scrollController.jumpTo(0.0);
          await Future.delayed(const Duration(seconds: 1));
        } else {
          await Future.delayed(const Duration(seconds: 2));
        }
      } else {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  @override
  void dispose() {
    _isScrolling = false;
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
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}

class TrackedChatView extends StatefulWidget {
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
  State<TrackedChatView> createState() => _TrackedChatViewState();
}

class _TrackedChatViewState extends State<TrackedChatView> {
  late ScrollController _scrollController;
  Timer? _initialTimer;
  bool _userScrolled = false;
  bool _hasUnreadMessages = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    
    _startAutoScrollTimer();
    widget.messagesNotifier.addListener(_onMessagesUpdated);
  }
  
  void _startAutoScrollTimer() {
    if (_userScrolled) return;
    _initialTimer?.cancel();
    _initialTimer = Timer(const Duration(seconds: 3), () {
      _scrollToBottom();
    });
  }

  void _onMessagesUpdated() {
    if (_userScrolled && _scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.offset;
      if (maxScroll - currentScroll <= 50) {
        _userScrolled = false;
      }
    }

    if (_userScrolled) {
      setState(() {
        _hasUnreadMessages = true;
      });
    }

    // Re-trigger auto scroll when new messages arrive if not manually scrolled
    if (!_userScrolled) {
      _startAutoScrollTimer();
    }
  }

  void _scrollToBottom() {
    if (!mounted || !_scrollController.hasClients || _userScrolled) return;
    
    // We delay the actual distance calc a frame to let the new messages render if called right after an update
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients || _userScrolled) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.offset;
      
      if (maxScroll > currentScroll) {
         final distance = maxScroll - currentScroll;
         // 60 ms per pixel (slower scroll)
         final duration = Duration(milliseconds: (distance * 60).toInt());
         _scrollController.animateTo(
           maxScroll,
           duration: duration,
           curve: Curves.linear,
         );
      }
    });
  }

  @override
  void dispose() {
    _initialTimer?.cancel();
    widget.messagesNotifier.removeListener(_onMessagesUpdated);
    _scrollController.dispose();
    super.dispose();
  }

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
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AutoScrollText(
                    text: widget.title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "Tracking via ${widget.appName}",
                    style: TextStyle(fontSize: 11, color: onSurface.withOpacity(0.6)),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_top, size: 20),
              tooltip: "Back to top & resume auto-scroll",
              onPressed: () {
                _userScrolled = false;
                if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    0.0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                }
                _startAutoScrollTimer();
              },
            ),
          ],
        ),
        const Divider(),
        Expanded(
          child: ValueListenableBuilder<List<Map<String, String>>>(
            valueListenable: widget.messagesNotifier,
            builder: (context, messages, _) {
              if (messages.isEmpty) {
                return Center(
                  child: Text(
                    "No messages tracked yet.",
                    style: TextStyle(color: onSurface.withOpacity(0.5)),
                  ),
                );
              }

                  return Stack(
                    children: [
                      Positioned.fill(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is UserScrollNotification && notification.direction != ScrollDirection.idle) {
                              if (!_userScrolled) {
                                _userScrolled = true;
                                _initialTimer?.cancel();
                              }
                            }
                            if (notification is ScrollUpdateNotification) {
                              if (_hasUnreadMessages && notification.metrics.maxScrollExtent - notification.metrics.pixels <= 50) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted) setState(() { _hasUnreadMessages = false; });
                                });
                              }
                            }
                            return false;
                          },
                          child: ListView.builder(
                            controller: _scrollController,
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
                          ),
                        ),
                      ),
                      if (_hasUnreadMessages)
                        Positioned(
                          bottom: 16,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _hasUnreadMessages = false;
                                  _userScrolled = false;
                                });
                                _scrollToBottom();
                                _startAutoScrollTimer();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.arrow_downward, size: 16, color: Colors.white),
                                    const SizedBox(width: 8),
                                    const Text(
                                      "New Message",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
              },
            ),
        ),
      ],
    );
  }
}
