import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/dynamic_theme.dart';

class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final themeProvider = Provider.of<DynamicThemeProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return AlertDialog(
      backgroundColor: theme.cardColor,
      title: Row(
        children: [
          Icon(Icons.settings, color: onSurface.withOpacity(0.7)),
          const SizedBox(width: 10),
          Text("Settings", style: TextStyle(color: onSurface)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Units Toggle
            ListTile(
              title: Text("Speed Unit", style: TextStyle(color: onSurface)),
              subtitle: Text(provider.isKmph ? "Kilometers per hour (km/h)" : "Miles per hour (mph)", style: TextStyle(color: onSurface.withOpacity(0.54))),
              trailing: Switch(
                value: provider.isKmph,
                onChanged: (_) => provider.toggleUnit(),
                activeColor: theme.colorScheme.primary,
              ),
            ),
            Divider(color: onSurface.withOpacity(0.1)),
            
            // Theme Override
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Text("Theme Override", style: TextStyle(color: onSurface, fontWeight: FontWeight.bold)),
            ),
            Wrap(
              spacing: 8.0,
              children: ['Auto', 'Day', 'Evening', 'Night'].map((themeName) {
                return ChoiceChip(
                  label: Text(themeName),
                  selected: false, // We could track the forced theme, but for simplicity we just apply it
                  onSelected: (selected) {
                    if (selected) {
                      if (themeName == 'Auto') {
                         themeProvider.forceTheme('Auto');
                      } else {
                         themeProvider.forceTheme(themeName);
                      }
                    }
                  },
                );
              }).toList(),
            ),
            Divider(color: onSurface.withOpacity(0.1)),

            // Demo Mode
            ListTile(
              title: Text("Demo Mode", style: TextStyle(color: onSurface)),
              subtitle: Text("Simulate driving", style: TextStyle(color: onSurface.withOpacity(0.54))),
              trailing: Switch(
                value: provider.isDemoMode,
                onChanged: (_) => provider.toggleDemoMode(),
                activeColor: theme.colorScheme.primary,
              ),
            ),
            Divider(color: onSurface.withOpacity(0.1)),
            
            // Theme Simulator
            ListTile(
              title: Text("Simulate Day/Night", style: TextStyle(color: onSurface)),
              subtitle: Text("Fast-forward time to see theme changes", style: TextStyle(color: onSurface.withOpacity(0.54))),
              trailing: Switch(
                value: themeProvider.isSimulating,
                onChanged: (_) => themeProvider.toggleSimulation(),
                activeColor: theme.colorScheme.primary,
              ),
            ),
            Divider(color: onSurface.withOpacity(0.1)),

            // System Permissions
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Text("System Permissions", style: TextStyle(color: onSurface, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              title: Text("Notification Access", style: TextStyle(color: onSurface, fontSize: 13)),
              subtitle: Text(
                provider.hasNotificationAccess ? "Granted" : "Required for Alerts & Media Sync",
                style: TextStyle(color: provider.hasNotificationAccess ? Colors.green : Colors.red, fontSize: 11),
              ),
              trailing: provider.hasNotificationAccess 
                  ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => provider.requestNotificationAccess(),
                      child: const Text("GRANT", style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
            ),
            ListTile(
              title: Text("Draw Overlays", style: TextStyle(color: onSurface, fontSize: 13)),
              subtitle: Text(
                provider.canDrawOverlays ? "Granted" : "Required to prevent snap-back",
                style: TextStyle(color: provider.canDrawOverlays ? Colors.green : Colors.orange, fontSize: 11),
              ),
              trailing: provider.canDrawOverlays 
                  ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => provider.requestOverlayPermission(),
                      child: const Text("FIX", style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
            ),
            ListTile(
              title: Text("Default Phone App", style: TextStyle(color: onSurface, fontSize: 13)),
              subtitle: Text(
                provider.isDefaultDialer ? "Active" : "Required for seamless calling",
                style: TextStyle(color: provider.isDefaultDialer ? Colors.green : Colors.red, fontSize: 11),
              ),
              trailing: provider.isDefaultDialer 
                  ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => provider.requestDefaultDialer(),
                      child: const Text("SET", style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text("CLOSE", style: TextStyle(color: theme.colorScheme.primary)),
        ),
      ],
    );
  }
}
