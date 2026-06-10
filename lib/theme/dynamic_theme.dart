import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

class DynamicThemeProvider with ChangeNotifier {
  ThemeData _currentTheme;
  Timer? _timer;

  // Day Theme (Bright and Light)
  static const _dayPrimary = Color(0xFF0066FF);
  static const _dayBackground = Color(0xFFF0F4F8);
  static const _dayCard = Color(0xFFFFFFFF);
  static const _dayText = Colors.black87;

  // Evening Theme (Sunset Orange/Red)
  static const _eveningPrimary = Color(0xFFFF5722);
  static const _eveningBackground = Color(0xFF2D1B16);
  static const _eveningCard = Color(0xFF3E2723);
  static const _eveningText = Colors.white;

  // Night Theme (Deep Dark)
  static const _nightPrimary = Color(0xFF00E5FF);
  static const _nightBackground = Color(0xFF050508);
  static const _nightCard = Color(0xFF101018);
  static const _nightText = Colors.white;

  bool _isSimulating = false;
  DateTime? _simulatedTime;

  DynamicThemeProvider() : _currentTheme = _calculateTheme(DateTime.now()) {
    _startTimer();
  }

  bool get isSimulating => _isSimulating;

  void toggleSimulation() {
    _isSimulating = !_isSimulating;
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_isSimulating) {
      _simulatedTime = DateTime(2026, 1, 1, 0, 0); // Start at midnight
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        _simulatedTime = _simulatedTime!.add(const Duration(minutes: 10));
        _currentTheme = _calculateTheme(_simulatedTime!);
        notifyListeners();
      });
    } else {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        _currentTheme = _calculateTheme(DateTime.now());
        notifyListeners();
      });
      _currentTheme = _calculateTheme(DateTime.now());
      notifyListeners();
    }
  }

  ThemeData get currentTheme => _currentTheme;

  static ThemeData _calculateTheme(DateTime time) {
    final double hours = time.hour + (time.minute / 60.0);
    
    Color primary;
    Color background;
    Color card;
    Color text;
    Brightness brightness;

    if (hours >= 4.0 && hours < 12.0) {
      // 4 AM to 12 PM: Smooth transition from Night to Day
      final double t = (hours - 4.0) / 8.0;
      primary = Color.lerp(_nightPrimary, _dayPrimary, t)!;
      background = Color.lerp(_nightBackground, _dayBackground, t)!;
      card = Color.lerp(_nightCard, _dayCard, t)!;
      
      // Darken primary color during the middle of the transition for better contrast on grey background
      final double dip = math.sin(t * math.pi);
      primary = Color.lerp(primary, Colors.black, dip * 0.4)!;

      brightness = t > 0.5 ? Brightness.light : Brightness.dark;
      text = brightness == Brightness.light ? _dayText : _nightText;
    } else if (hours >= 12.0 && hours < 18.0) {
      // 12 PM to 6 PM: Smooth transition from Day to Evening
      final double t = (hours - 12.0) / 6.0;
      primary = Color.lerp(_dayPrimary, _eveningPrimary, t)!;
      background = Color.lerp(_dayBackground, _eveningBackground, t)!;
      card = Color.lerp(_dayCard, _eveningCard, t)!;

      // Darken primary color during the middle of the transition for better contrast on grey background
      final double dip = math.sin(t * math.pi);
      primary = Color.lerp(primary, Colors.black, dip * 0.4)!;

      brightness = t > 0.5 ? Brightness.dark : Brightness.light;
      text = brightness == Brightness.light ? _dayText : _eveningText;
    } else if (hours >= 18.0 && hours < 22.0) {
      // 6 PM to 10 PM: Smooth transition from Evening to Night
      final double t = (hours - 18.0) / 4.0;
      primary = Color.lerp(_eveningPrimary, _nightPrimary, t)!;
      background = Color.lerp(_eveningBackground, _nightBackground, t)!;
      card = Color.lerp(_eveningCard, _nightCard, t)!;
      brightness = Brightness.dark;
      text = _nightText;
    } else {
      // 10 PM to 4 AM: Night time (flat)
      primary = _nightPrimary;
      background = _nightBackground;
      card = _nightCard;
      text = _nightText;
      brightness = Brightness.dark;
    }

    return _buildTheme(primary, background, card, text, brightness);
  }

  static ThemeData _buildTheme(Color primary, Color background, Color card, Color text, Brightness brightness) {
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: background,
      cardColor: card,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: Colors.white,
        secondary: primary.withOpacity(0.8),
        onSecondary: Colors.white,
        error: Colors.redAccent,
        onError: Colors.white,
        surface: card,
        onSurface: text,
      ),
      iconTheme: IconThemeData(color: text.withOpacity(0.9)),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: text),
        bodyMedium: TextStyle(color: text.withOpacity(0.8)),
      ),
    );
  }

  void forceTheme(String timeOfDay) {
    if (timeOfDay == 'Day') { // Maps to Day
      _currentTheme = _buildTheme(_dayPrimary, _dayBackground, _dayCard, _dayText, Brightness.light);
    } else if (timeOfDay == 'Evening') {
      _currentTheme = _buildTheme(_eveningPrimary, _eveningBackground, _eveningCard, _eveningText, Brightness.dark);
    } else if (timeOfDay == 'Night') {
      _currentTheme = _buildTheme(_nightPrimary, _nightBackground, _nightCard, _nightText, Brightness.dark);
    } else {
      _currentTheme = _calculateTheme(DateTime.now());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
