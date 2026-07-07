import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../theme/dynamic_theme.dart';
import '../services/collab_service.dart';
import '../services/youtube_service.dart';

/// Fullscreen, reorganized settings page. Rendered as a top-level Stack layer
/// (see main.dart) rather than a floating dialog. Each feature can be toggled
/// on/off; features that need an Android permission show a live status row with
/// a Grant button and stay dormant until the permission is granted.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh permission status so the cards reflect reality when opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = Provider.of<DashboardProvider>(context, listen: false);
      provider.checkPermissions();
      provider.checkPhonePermissions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final provider = context.watch<DashboardProvider>();

    return Positioned.fill(
      child: Material(
        color: theme.scaffoldBackgroundColor,
        child: SafeArea(
          left: false,
          right: false,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                child: Row(
                  children: [
                    Icon(Icons.settings, color: onSurface.withOpacity(0.8), size: 22),
                    const SizedBox(width: 12),
                    Text(
                      "Settings",
                      style: TextStyle(
                        color: onSurface,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: onSurface.withOpacity(0.7)),
                      onPressed: () => provider.dismissSettingsUI(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: onSurface.withOpacity(0.08)),
              // Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: const [
                          _DrivingSection(),
                          _MediaCollabSection(),
                          _PhoneSection(),
                          _NotificationsSection(),
                          _DisplaySystemSection(),
                          _DeveloperSection(),
                          _PermissionsOverviewSection(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Driving & Speed
// ─────────────────────────────────────────────────────────────────────────────
class _DrivingSection extends StatelessWidget {
  const _DrivingSection();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();
    final hasLocation = provider.hasLocationPermission;

    return _Section(
      title: "Driving & Speed",
      icon: Icons.drive_eta_rounded,
      children: [
        _FeatureCard(
          title: "Speed unit",
          subtitle: provider.isKmph ? "Kilometers per hour (km/h)" : "Miles per hour (mph)",
          value: provider.isKmph,
          onChanged: (_) => provider.toggleUnit(),
          switchLabel: provider.isKmph ? "km/h" : "mph",
        ),
        _FeatureCard(
          title: "Speed limit display",
          subtitle: "Shows the posted speed-limit sign on the gauge.",
          value: provider.featSpeedLimit,
          onChanged: (v) => provider.setFeatSpeedLimit(v),
          permissions: [
            _PermStatus(
              label: "Location",
              granted: hasLocation,
              note: "needed to look up limits",
              onGrant: () => provider.checkLocationSettingsAndPermissions(),
            ),
          ],
        ),
        _FeatureCard(
          title: "Over-speed warning",
          subtitle: "Turns the speed red and highlights the gauge above the limit.",
          value: provider.featSpeedWarning,
          onChanged: (v) => provider.setFeatSpeedWarning(v),
          permissions: [
            _PermStatus(
              label: "Location",
              granted: hasLocation,
              note: "needed to know the limit",
              onGrant: () => provider.checkLocationSettingsAndPermissions(),
            ),
          ],
        ),
        _FeatureCard(
          title: "\"Ready to drive?\" overlay",
          subtitle: "Prompts for destination + music when you return to the car.",
          value: provider.featWelcomeOverlay,
          onChanged: (v) => provider.setFeatWelcomeOverlay(v),
        ),
        _FeatureCard(
          title: "Auto-launch Maps",
          subtitle: "Opens Google Maps navigation from the drive prompt.",
          value: provider.featMapsAutolaunch,
          onChanged: (v) => provider.setFeatMapsAutolaunch(v),
        ),
        _FeatureCard(
          title: "Dashcam",
          subtitle: "Enables dashcam auto-start and the REC indicator.",
          value: provider.featDashcam,
          onChanged: (v) => provider.setFeatDashcam(v),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Media & Collab
// ─────────────────────────────────────────────────────────────────────────────
class _MediaCollabSection extends StatelessWidget {
  const _MediaCollabSection();

  @override
  Widget build(BuildContext context) {
    final collab = context.watch<CollabService>();

    return _Section(
      title: "Media & Collab",
      icon: Icons.queue_music_rounded,
      children: [
        _FeatureCard(
          title: "Collaborative playback",
          subtitle: "Lets passengers scan the QR and add to the queue from their phones.",
          value: collab.enabled,
          onChanged: (v) => v ? collab.enable() : collab.disable(),
        ),
        if (collab.enabled) ...[
          _FeatureCard(
            title: "Allow passengers to edit",
            subtitle: "Passengers can reorder and remove queue items.",
            value: collab.allowEditing,
            onChanged: (v) => collab.setAllowEditing(v),
            indent: true,
          ),
          _FeatureCard(
            title: "Allow passenger media control",
            subtitle: "Passengers can play/pause, skip, and tap-to-play.",
            value: collab.allowMediaControl,
            onChanged: (v) => collab.setAllowMediaControl(v),
            indent: true,
          ),
        ],
        const _GoogleAccountCard(),
      ],
    );
  }
}

/// Optional Google sign-in — only powers the passenger "search YouTube for demos"
/// toggle (the YouTube Data API). Everything else in Collab/Favorites is anonymous,
/// so this is a convenience, not a requirement.
class _GoogleAccountCard extends StatelessWidget {
  const _GoogleAccountCard();

  @override
  Widget build(BuildContext context) {
    final yt = context.watch<YouTubeService>();
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final signedIn = yt.isSignedIn;
    final email = yt.currentUser?.email ?? '';

    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "YouTube account (demo search)",
                      style: TextStyle(color: onSurface, fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "Optional. Sign in to let passengers search all of YouTube for demos "
                      "and unreleased tracks (the \"Search YouTube\" toggle). Normal YT Music "
                      "search, playback and favorites work signed out.",
                      style: TextStyle(color: onSurface.withOpacity(0.6), fontSize: 12, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                signedIn ? Icons.check_circle : Icons.account_circle_outlined,
                color: signedIn ? Colors.green : onSurface.withOpacity(0.4),
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  signedIn ? (email.isNotEmpty ? email : "Signed in") : "Not signed in",
                  style: TextStyle(color: onSurface.withOpacity(0.75), fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (signedIn)
                TextButton(
                  onPressed: () => yt.signOut(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    "SIGN OUT",
                    style: TextStyle(color: onSurface.withOpacity(0.6), fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                )
              else
                TextButton(
                  onPressed: () async {
                    try {
                      await yt.signIn();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("Google sign-in failed: $e"),
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: theme.colorScheme.primary.withOpacity(0.12),
                  ),
                  child: Text(
                    "SIGN IN",
                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Phone
// ─────────────────────────────────────────────────────────────────────────────
class _PhoneSection extends StatelessWidget {
  const _PhoneSection();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final mode = provider.phoneMode;

    String behaviour;
    switch (mode) {
      case 0:
        behaviour = "Incoming/outgoing calls are ignored by the dashboard. Your phone's own dialer handles everything.";
        break;
      case 2:
        behaviour = "Carpanion becomes the default phone app — full in-car call screen for every call. Needs the default-dialer role.";
        break;
      default:
        behaviour = "Shows the in-car call screen while another dialer stays default. Needs phone + contacts permission.";
    }

    return _Section(
      title: "Phone",
      icon: Icons.phone_rounded,
      children: [
        _CardShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Call handling",
                style: TextStyle(color: onSurface, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              _SegmentedControl(
                options: const ["Off", "In-app only", "Full (default)"],
                selectedIndex: mode,
                onSelected: (i) {
                  provider.setPhoneMode(i);
                  if (i == 1 && !provider.hasPhonePermissions) {
                    provider.requestPhonePermissions();
                  } else if (i == 2 && !provider.isDefaultDialer) {
                    provider.requestDefaultDialer();
                  }
                },
              ),
              const SizedBox(height: 10),
              Text(
                behaviour,
                style: TextStyle(color: onSurface.withOpacity(0.6), fontSize: 12, height: 1.4),
              ),
              if (mode != 0) ...[
                const SizedBox(height: 12),
                _PermStatus(
                  label: "Phone & contacts",
                  granted: provider.hasPhonePermissions,
                  note: "read call state + caller names",
                  onGrant: () => provider.requestPhonePermissions(),
                ).build(context),
              ],
              if (mode == 2) ...[
                const SizedBox(height: 8),
                _PermStatus(
                  label: "Default phone app",
                  granted: provider.isDefaultDialer,
                  note: "required for full mode",
                  onGrant: () => provider.requestDefaultDialer(),
                ).build(context),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Notifications
// ─────────────────────────────────────────────────────────────────────────────
class _NotificationsSection extends StatelessWidget {
  const _NotificationsSection();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();

    return _Section(
      title: "Notifications",
      icon: Icons.notifications_rounded,
      children: [
        _FeatureCard(
          title: "Notification tracking",
          subtitle: "Collects app alerts and chat messages into the Alerts tab.",
          value: provider.featNotifications,
          onChanged: (v) => provider.setFeatNotifications(v),
          permissions: [
            _PermStatus(
              label: "Notification access",
              granted: provider.hasNotificationAccess,
              note: "also powers media sync & dashcam detection",
              onGrant: () => provider.requestNotificationAccess(),
            ),
          ],
          footnote: "The OS notification-access permission is shared with media sync and dashcam detection, so turning this off keeps those working.",
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Display & System
// ─────────────────────────────────────────────────────────────────────────────
class _DisplaySystemSection extends StatelessWidget {
  const _DisplaySystemSection();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();
    final themeProvider = context.watch<DynamicThemeProvider>();
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return _Section(
      title: "Display & System",
      icon: Icons.brightness_6_rounded,
      children: [
        _CardShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Theme", style: TextStyle(color: onSurface, fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                "Auto follows the time of day.",
                style: TextStyle(color: onSurface.withOpacity(0.6), fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8.0,
                children: ['Auto', 'Day', 'Evening', 'Night'].map((name) {
                  return ActionChip(
                    label: Text(name),
                    onPressed: () => themeProvider.forceTheme(name),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        _FeatureCard(
          title: "Adaptive brightness",
          subtitle: "Lets Android adjust screen brightness automatically.",
          value: provider.isAdaptiveBrightness,
          onChanged: (_) => provider.toggleAdaptiveBrightness(),
        ),
        _FeatureCard(
          title: "Keep app in foreground",
          subtitle: "Draw-over-other-apps stops the dashboard from snapping away after launching Maps/Music.",
          value: provider.canDrawOverlays,
          onChanged: provider.canDrawOverlays ? null : (_) => provider.requestOverlayPermission(),
          permissions: [
            _PermStatus(
              label: "Draw over other apps",
              granted: provider.canDrawOverlays,
              note: "prevents snap-back",
              onGrant: () => provider.requestOverlayPermission(),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Developer
// ─────────────────────────────────────────────────────────────────────────────
class _DeveloperSection extends StatelessWidget {
  const _DeveloperSection();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();
    final themeProvider = context.watch<DynamicThemeProvider>();

    return _Section(
      title: "Developer",
      icon: Icons.bug_report_rounded,
      children: [
        _FeatureCard(
          title: "Demo mode",
          subtitle: "Simulates driving with fake speed/GPS data.",
          value: provider.isDemoMode,
          onChanged: (_) => provider.toggleDemoMode(),
        ),
        _FeatureCard(
          title: "Simulate day/night",
          subtitle: "Fast-forwards the clock to preview theme transitions.",
          value: themeProvider.isSimulating,
          onChanged: (_) => themeProvider.toggleSimulation(),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Permissions overview
// ─────────────────────────────────────────────────────────────────────────────
class _PermissionsOverviewSection extends StatelessWidget {
  const _PermissionsOverviewSection();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();

    return _Section(
      title: "Permissions overview",
      icon: Icons.verified_user_rounded,
      children: [
        _CardShell(
          child: Column(
            children: [
              _PermStatus(
                label: "Location",
                granted: provider.hasLocationPermission,
                note: "speed, limits, street name",
                onGrant: () => provider.checkLocationSettingsAndPermissions(),
              ).build(context),
              const SizedBox(height: 10),
              _PermStatus(
                label: "Notification access",
                granted: provider.hasNotificationAccess,
                note: "alerts, media sync, dashcam",
                onGrant: () => provider.requestNotificationAccess(),
              ).build(context),
              const SizedBox(height: 10),
              _PermStatus(
                label: "Draw over other apps",
                granted: provider.canDrawOverlays,
                note: "keep dashboard foreground",
                onGrant: () => provider.requestOverlayPermission(),
              ).build(context),
              const SizedBox(height: 10),
              _PermStatus(
                label: "Phone & contacts",
                granted: provider.hasPhonePermissions,
                note: "in-car call screen",
                onGrant: () => provider.requestPhonePermissions(),
              ).build(context),
              const SizedBox(height: 10),
              _PermStatus(
                label: "Default phone app",
                granted: provider.isDefaultDialer,
                note: "full call handling",
                onGrant: () => provider.requestDefaultDialer(),
              ).build(context),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable pieces
// ─────────────────────────────────────────────────────────────────────────────
class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _Section({required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8, left: 4),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

class _CardShell extends StatelessWidget {
  final Widget child;
  final bool indent;
  const _CardShell({required this.child, this.indent = false});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      margin: EdgeInsets.only(bottom: 8, left: indent ? 20 : 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: onSurface.withOpacity(0.06)),
      ),
      child: child,
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final List<_PermStatus> permissions;
  final String? footnote;
  final String? switchLabel;
  final bool indent;

  const _FeatureCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.permissions = const [],
    this.footnote,
    this.switchLabel,
    this.indent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    // A feature that's ON but missing a required permission is dormant.
    final dormant = value && permissions.isNotEmpty && permissions.any((p) => !p.granted);

    return _CardShell(
      indent: indent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(color: onSurface, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (dormant) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              "NEEDS PERMISSION",
                              style: TextStyle(color: Colors.orange, fontSize: 8, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(color: onSurface.withOpacity(0.6), fontSize: 12, height: 1.3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (switchLabel != null)
                Text(
                  switchLabel!,
                  style: TextStyle(color: onSurface.withOpacity(0.5), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              Switch(
                value: value,
                onChanged: onChanged,
                activeColor: theme.colorScheme.primary,
              ),
            ],
          ),
          for (final p in permissions) ...[
            const SizedBox(height: 8),
            p.build(context),
          ],
          if (footnote != null) ...[
            const SizedBox(height: 8),
            Text(
              footnote!,
              style: TextStyle(color: onSurface.withOpacity(0.4), fontSize: 10.5, height: 1.3, fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single permission status row (green check when granted, Grant button when
/// not). Not a widget subclass — call `.build(context)` where it's placed.
class _PermStatus {
  final String label;
  final bool granted;
  final String note;
  final VoidCallback onGrant;

  const _PermStatus({
    required this.label,
    required this.granted,
    required this.note,
    required this.onGrant,
  });

  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return Row(
      children: [
        Icon(
          granted ? Icons.check_circle : Icons.error_outline,
          color: granted ? Colors.green : Colors.orange,
          size: 16,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(color: onSurface.withOpacity(0.7), fontSize: 11.5),
              children: [
                TextSpan(text: label, style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: "  •  $note", style: TextStyle(color: onSurface.withOpacity(0.45))),
              ],
            ),
          ),
        ),
        if (granted)
          Text(
            "Granted",
            style: TextStyle(color: Colors.green.withOpacity(0.9), fontSize: 11, fontWeight: FontWeight.w600),
          )
        else
          TextButton(
            onPressed: onGrant,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: theme.colorScheme.primary.withOpacity(0.12),
            ),
            child: Text(
              "GRANT",
              style: TextStyle(color: theme.colorScheme.primary, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
  }
}

class _SegmentedControl extends StatelessWidget {
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _SegmentedControl({
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return Container(
      decoration: BoxDecoration(
        color: onSurface.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: List.generate(options.length, (i) {
          final selected = i == selectedIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => onSelected(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: selected ? theme.colorScheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  options[i],
                  style: TextStyle(
                    color: selected ? theme.colorScheme.onPrimary : onSurface.withOpacity(0.6),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
