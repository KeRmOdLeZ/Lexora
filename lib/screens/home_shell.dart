import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/lexora_theme.dart';

/// Main bottom-navigation shell hosting Ana Sayfa, Sözlük, and Ayarlar.
class HomeShell extends StatelessWidget {
  const HomeShell({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion(
      value: LexoraTheme.overlayStyleFor(theme.brightness),
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (index) {
              navigationShell.goBranch(
                index,
                initialLocation: index == navigationShell.currentIndex,
              );
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Ana Sayfa',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book_rounded),
                label: 'Sözlük',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: 'Ayarlar',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
