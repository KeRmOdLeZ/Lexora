import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/word_entry.dart';
import '../screens/dashboard_screen.dart';
import '../screens/dictionary_screen.dart';
import '../screens/evening_cloze_screen.dart';
import '../screens/home_shell.dart';
import '../screens/morning_session_screen.dart';
import '../screens/placement_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/setup_screen.dart';
import '../screens/vocab_notebook_screen.dart';
import '../screens/word_detail_screen.dart';
import '../services/app_bootstrap.dart';
import '../state/app_providers.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

class _RouterRefreshNotifier extends ChangeNotifier {
  void trigger() => notifyListeners();
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _RouterRefreshNotifier();
  ref.listen<BootstrapState>(bootstrapControllerProvider, (_, _) {
    refreshNotifier.trigger();
  });
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/setup',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final boot = ref.read(bootstrapControllerProvider);
      final loc = state.matchedLocation;

      if (boot.stage != BootstrapStage.ready) {
        return loc == '/setup' ? null : '/setup';
      }

      if (!boot.placementCompleted) {
        return loc == '/placement' ? null : '/placement';
      }

      if (loc == '/setup' || loc == '/placement') {
        final pendingWord = ref
            .read(bootstrapControllerProvider.notifier)
            .consumePendingDeepLink();
        if (pendingWord != null && pendingWord.isNotEmpty) {
          return '/word/${Uri.encodeComponent(pendingWord)}?depth=2';
        }
        return '/dashboard';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/setup',
        builder: (_, _) => const SetupScreen(),
      ),
      GoRoute(
        path: '/placement',
        builder: (_, _) => const PlacementScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return HomeShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (_, _) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dictionary',
                builder: (_, _) => const DictionaryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/morning',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) {
          final isExtra = state.uri.queryParameters['extra'] == '1';
          return MorningSessionScreen(isExtraPractice: isExtra);
        },
      ),
      GoRoute(
        path: '/evening',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const EveningClozeScreen(),
      ),
      GoRoute(
        path: '/notebook',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) {
          final bucketParam = state.uri.queryParameters['bucket'];
          final bucket = switch (bucketParam) {
            'learning' => MasteryBucket.learning,
            'consolidating' => MasteryBucket.consolidating,
            'mastered' => MasteryBucket.mastered,
            _ => MasteryBucket.all,
          };
          return VocabNotebookScreen(initialBucket: bucket);
        },
      ),
      GoRoute(
        path: '/word/:key',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) {
          final rawKey = state.pathParameters['key'] ?? '';
          final decoded = Uri.decodeComponent(rawKey);
          final depth =
              int.tryParse(state.uri.queryParameters['depth'] ?? '1') ?? 1;
          return WordDetailScreen(wordKey: decoded, navDepth: depth);
        },
      ),
    ],
  );
});
