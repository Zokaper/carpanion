import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'main.dart';

class SpeedometerWidget extends StatelessWidget {
  const SpeedometerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    
    final speed = provider.isKmph 
        ? provider.speed * 3.6 
        : provider.speed * 2.23694;
        
    final speedString = speed.toInt().toString();
    final maxSpeed = provider.isKmph ? 240.0 : 160.0;
    final speedPercent = (speed / maxSpeed).clamp(0.0, 1.0);

    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: onSurface.withOpacity(0.05)),
      ),
      child: Stack(
        children: [
          // Main Content
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Meaningful Circular Gauge
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: CustomPaint(
                          painter: _SpeedGaugePainter(
                            percentage: speedPercent,
                            trackColor: onSurface.withOpacity(0.05),
                            progressColor: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    
                    // Centered Digital Speed
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          speedString,
                          style: TextStyle(
                            color: onSurface,
                            fontSize: 68,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                            letterSpacing: -2,
                          ),
                        ),
                        Text(
                          provider.isKmph ? "KM/H" : "MPH",
                          style: TextStyle(
                            color: onSurface.withOpacity(0.4),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                    
                    // Speed Limit Sign
                    Positioned(
                      bottom: 0,
                      child: Container(
                         width: 44,
                         height: 44,
                         decoration: BoxDecoration(
                           color: Colors.white, // Speed signs are always white bg with red border
                           shape: BoxShape.circle,
                           border: Border.all(color: Colors.red, width: 4),
                         ),
                         alignment: Alignment.center,
                         child: Text(
                           provider.speedLimit,
                           style: const TextStyle(
                             color: Colors.black,
                             fontWeight: FontWeight.w900,
                             fontSize: 16,
                           ),
                         ),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Extra Metrics (Altitude, Heading, Street Name)
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildMetricItem(Icons.height, "${provider.altitude.toStringAsFixed(0)} M", onSurface),
                  _buildMetricItem(Icons.explore, _getHeadingString(provider.heading), onSurface),
                ],
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  provider.streetName,
                  style: TextStyle(
                    color: onSurface.withOpacity(0.5),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          
          // Floating Header overlay (takes 0 vertical space from the main layout)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Row(
              children: [
                Icon(Icons.drive_eta_rounded, color: onSurface.withOpacity(0.5), size: 16),
                const SizedBox(width: 8),
                Text(
                  "GPS",
                  style: TextStyle(
                    color: onSurface.withOpacity(0.5),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const Spacer(),
                if (provider.dashcamRecording)
                   Row(
                     children: [
                       Container(
                         width: 8, height: 8,
                         decoration: const BoxDecoration(
                           color: Colors.red,
                           shape: BoxShape.circle,
                         ),
                       ),
                       const SizedBox(width: 4),
                       const Text("REC", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
                       const SizedBox(width: 12),
                     ],
                   ),
                Icon(
                  provider.hasLocationPermission ? Icons.gps_fixed : Icons.gps_off,
                  color: provider.hasLocationPermission ? onSurface.withOpacity(0.3) : Colors.red,
                  size: 14,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricItem(IconData icon, String value, Color onSurface) {
    return Row(
      children: [
        Icon(icon, color: onSurface.withOpacity(0.3), size: 14),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: onSurface.withOpacity(0.7),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  String _getHeadingString(double heading) {
    if (heading >= 337.5 || heading < 22.5) return 'N';
    if (heading >= 22.5 && heading < 67.5) return 'NE';
    if (heading >= 67.5 && heading < 112.5) return 'E';
    if (heading >= 112.5 && heading < 157.5) return 'SE';
    if (heading >= 157.5 && heading < 202.5) return 'S';
    if (heading >= 202.5 && heading < 247.5) return 'SW';
    if (heading >= 247.5 && heading < 292.5) return 'W';
    if (heading >= 292.5 && heading < 337.5) return 'NW';
    return '';
  }
}

class _SpeedGaugePainter extends CustomPainter {
  final double percentage;
  final Color trackColor;
  final Color progressColor;

  _SpeedGaugePainter({
    required this.percentage,
    required this.trackColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width / 2, size.height / 2);
    
    // Start angle: 135 degrees (bottom left)
    // Sweep angle: 270 degrees
    const startAngle = 135 * pi / 180;
    const sweepAngle = 270 * pi / 180;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle * percentage,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SpeedGaugePainter oldDelegate) {
    return oldDelegate.percentage != percentage;
  }
}
