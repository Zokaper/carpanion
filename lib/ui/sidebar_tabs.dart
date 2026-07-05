import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import 'phone_tab.dart';
import 'notifications_tab.dart';

// We reuse the FavoritesSidebar from main.dart for the Media tab.
// Since it's still in main.dart, we can just import it.

class HeaderTabsWidget extends StatelessWidget {
  const HeaderTabsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DashboardProvider>(context);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Container(
      width: double.infinity, // It is inside an Expanded(flex: 6), so let it fill
      padding: const EdgeInsets.all(4.0),
      decoration: BoxDecoration(
        color: onSurface.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: onSurface.withOpacity(0.05)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _TabButton(
            icon: Icons.music_note,
            title: "Media",
            isSelected: provider.selectedSidebarTab == 0,
            onTap: () => provider.setSidebarTab(0, isManual: true),
          ),
          _TabButton(
            icon: Icons.phone,
            title: "Phone",
            isSelected: provider.selectedSidebarTab == 1,
            onTap: () => provider.setSidebarTab(1, isManual: true),
          ),
          _TabButton(
            icon: Icons.notifications,
            title: "Alerts",
            isSelected: provider.selectedSidebarTab == 2,
            onTap: () => provider.setSidebarTab(2, isManual: true),
          ),
        ],
      ),
    );
  }
}

class SidebarContentWidget extends StatefulWidget {
  const SidebarContentWidget({super.key});

  @override
  State<SidebarContentWidget> createState() => _SidebarContentWidgetState();
}

class _SidebarContentWidgetState extends State<SidebarContentWidget> {
  late PageController _pageController;
  late DashboardProvider _provider;

  @override
  void initState() {
    super.initState();
    final initialTab = Provider.of<DashboardProvider>(context, listen: false).selectedSidebarTab;
    _pageController = PageController(initialPage: initialTab);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider = Provider.of<DashboardProvider>(context, listen: false);
      _provider.addListener(_onProviderChanged);
    });
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onProviderChanged() {
    if (_pageController.hasClients) {
      final providerPage = _provider.selectedSidebarTab;
      final currentPage = _pageController.page?.round();
      if (currentPage != providerPage) {
        _pageController.animateToPage(
          providerPage,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _pageController,
      physics: const StrictPageScrollPhysics(parent: ClampingScrollPhysics()),
      onPageChanged: (index) {
        final provider = Provider.of<DashboardProvider>(context, listen: false);
        if (provider.selectedSidebarTab != index) {
          provider.setSidebarTab(index, isManual: true);
        }
      },
      children: const [
        FavoritesSidebar(key: ValueKey(0)),
        PhoneTab(key: ValueKey(1)),
        NotificationsTab(key: ValueKey(2)),
      ],
    );
  }
}

class StrictPageScrollPhysics extends ScrollPhysics {
  const StrictPageScrollPhysics({super.parent});

  @override
  StrictPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return StrictPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }

    final Tolerance tolerance = this.tolerance;
    final double portion = position.pixels / position.viewportDimension;
    final double currentPage = portion.roundToDouble();
    
    double targetPage;
    if (velocity > 0.0) {
      targetPage = (portion.floorToDouble() + 1.0).clamp(0.0, 2.0);
    } else if (velocity < 0.0) {
      targetPage = (portion.ceilToDouble() - 1.0).clamp(0.0, 2.0);
    } else {
      targetPage = currentPage;
    }

    final double target = targetPage * position.viewportDimension;
    if (target != position.pixels) {
      return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tolerance);
    }
    return null;
  }
}

class _TabButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabButton({
    required this.icon,
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: isSelected ? theme.colorScheme.primary.withOpacity(0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: isSelected ? theme.colorScheme.primary : onSurface.withOpacity(0.54), size: 14),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: TextStyle(
                    color: isSelected ? theme.colorScheme.primary : onSurface.withOpacity(0.54),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
