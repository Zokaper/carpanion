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

    Color speedColor = onSurface;
    double? warningPct;
    double? dangerPct;

    if (provider.featSpeedWarning && provider.speedLimit != '?') {
      final intLimit = int.tryParse(provider.speedLimit);
      if (intLimit != null) {
        // provider.speed is in m/s, so we calculate km/h for the Saher logic
        final currentSpeedKmph = provider.speed * 3.6;
        final saherThreshold = intLimit <= 120 ? intLimit + 10 : intLimit + 5;
        
        if (currentSpeedKmph >= saherThreshold) {
          speedColor = Colors.red;
        } else if (currentSpeedKmph >= saherThreshold - 5) {
          speedColor = Colors.orange;
        }

        double thresholdUnit = provider.isKmph ? saherThreshold.toDouble() : saherThreshold / 1.60934;
        double warningUnit = provider.isKmph ? (saherThreshold - 5).toDouble() : (saherThreshold - 5) / 1.60934;
        
        warningPct = (warningUnit / maxSpeed).clamp(0.0, 1.0);
        dangerPct = (thresholdUnit / maxSpeed).clamp(0.0, 1.0);
      }
    }

    final progressBarColor = theme.colorScheme.primary;

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
                            progressColor: progressBarColor,
                            warningPercentage: warningPct,
                            dangerPercentage: dangerPct,
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
                            color: speedColor,
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
                    if (provider.featSpeedLimit)
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
                   GestureDetector(
                     onTap: () {
                       showDialog(
                         context: context,
                         builder: (context) => AlertDialog(
                           backgroundColor: Theme.of(context).colorScheme.surface,
                           title: const Text('Stop Recording?', style: TextStyle(fontWeight: FontWeight.bold)),
                           content: const Text('Are you sure you want to stop the dashcam recording?'),
                           actions: [
                             TextButton(
                               onPressed: () => Navigator.pop(context),
                               child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
                             ),
                             TextButton(
                               onPressed: () {
                                 provider.stopDashcam();
                                 Navigator.pop(context);
                               },
                               child: const Text('Stop', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                             ),
                           ],
                         ),
                       );
                     },
                     child: Row(
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
                   ),
                if (provider.hasLocationPermission)
                  _buildGpsSignalIndicator(provider.accuracy, onSurface)
                else
                  const Icon(
                    Icons.gps_off,
                    color: Colors.red,
                    size: 14,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGpsSignalIndicator(double accuracy, Color onSurface) {
    IconData icon;
    Color color;

    if (accuracy <= 0.0) {
      icon = Icons.signal_cellular_0_bar;
      color = onSurface.withOpacity(0.3);
    } else if (accuracy <= 8.0) {
      icon = Icons.signal_cellular_4_bar;
      color = Colors.green;
    } else if (accuracy <= 15.0) {
      icon = Icons.signal_cellular_4_bar;
      color = Colors.orange;
    } else if (accuracy <= 30.0) {
      icon = Icons.signal_cellular_4_bar;
      color = Colors.orange;
    } else {
      icon = Icons.signal_cellular_4_bar;
      color = Colors.red;
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 4),
        Text(
          accuracy > 0.0 ? "${accuracy.toStringAsFixed(0)}m" : "--",
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
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
  final double? warningPercentage;
  final double? dangerPercentage;

  _SpeedGaugePainter({
    required this.percentage,
    required this.trackColor,
    required this.progressColor,
    this.warningPercentage,
    this.dangerPercentage,
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
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    if (warningPercentage != null && dangerPercentage != null) {
      final gradient = SweepGradient(
        startAngle: 0.0,
        endAngle: sweepAngle,
        colors: [
          trackColor,
          trackColor,
          Colors.orange.withOpacity(0.4),
          Colors.orange.withOpacity(0.4),
          Colors.red.withOpacity(0.4),
          Colors.red.withOpacity(0.4),
        ],
        stops: [
          0.0,
          warningPercentage!,
          warningPercentage!,
          dangerPercentage!,
          dangerPercentage!,
          1.0,
        ],
        transform: GradientRotation(startAngle),
      );
      trackPaint.shader = gradient.createShader(Rect.fromCircle(center: center, radius: radius));
    } else {
      trackPaint.color = trackColor;
    }

    // Draw base track with colored redlines via gradient
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

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
    return oldDelegate.percentage != percentage ||
           oldDelegate.warningPercentage != warningPercentage ||
           oldDelegate.dangerPercentage != dangerPercentage;
  }
}
