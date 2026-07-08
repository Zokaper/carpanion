import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Full-screen in-app YouTube Music login (the SimpMusic/ViMusic approach): the
/// user signs into music.youtube.com in a WebView and we capture the resulting
/// first-party cookies. Pops with {cookie: <full Cookie header>, sapisid:
/// <__Secure-3PAPISID value>} on success, or null if the user backs out.
///
/// The auth cookie (`__Secure-3PAPISID`) is httpOnly, so JS `document.cookie`
/// can't see it — we read it natively via Android's shared `CookieManager`
/// (`getYtmCookies` handler), which the WebView writes to.
///
/// NOTE: reuses real first-party YT Music cookies against the public Innertube
/// key — the community-standard way to reach personalized data. User-initiated only.
class YtMusicLoginWebView extends StatefulWidget {
  const YtMusicLoginWebView({super.key});

  @override
  State<YtMusicLoginWebView> createState() => _YtMusicLoginWebViewState();
}

class _YtMusicLoginWebViewState extends State<YtMusicLoginWebView> {
  static const _platform = MethodChannel('com.example.car_dashboard/system');
  late final WebViewController _controller;
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 14; SM-S936B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) => _tryCapture(url),
      ))
      ..loadRequest(Uri.parse('https://music.youtube.com'));
  }

  Future<void> _tryCapture(String url) async {
    if (_captured || !mounted || !url.contains('music.youtube.com')) return;
    try {
      final cookieStr = await _platform.invokeMethod<String>('getYtmCookies');
      if (cookieStr == null || cookieStr.isEmpty) return;
      String? sapisid;
      for (final part in cookieStr.split(';')) {
        final kv = part.trim();
        if (kv.startsWith('__Secure-3PAPISID=')) {
          sapisid = kv.substring('__Secure-3PAPISID='.length);
        }
      }
      // SAPISID only exists once the user is actually signed in.
      if (sapisid != null && sapisid.isNotEmpty) {
        _captured = true;
        if (mounted) {
          Navigator.of(context).pop({'cookie': cookieStr, 'sapisid': sapisid});
        }
      }
    } catch (e) {
      debugPrint('getYtmCookies failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        foregroundColor: theme.colorScheme.onSurface,
        title: const Text('Connect YouTube Music'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
