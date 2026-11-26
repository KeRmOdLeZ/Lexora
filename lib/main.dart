import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'core/constants.dart';
import 'router/app_router.dart';
import 'services/app_bootstrap.dart';
import 'state/app_providers.dart';
import 'theme/lexora_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Immediately render lightweight Setup/Bootstrap shell without blocking runApp().
  runApp(const ProviderScope(child: LexoraApp()));
}

class LexoraApp extends ConsumerStatefulWidget {
  const LexoraApp({super.key});

  @override
  ConsumerState<LexoraApp> createState() => _LexoraAppState();
}

class _LexoraAppState extends ConsumerState<LexoraApp>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Uri?>? _widgetClickSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    Future.microtask(() {
      // Wire one-time gentle missing offline English TTS alert -> Android TTS settings.
      final audio = ref.read(audioServiceProvider);
      audio.onMissingEnglishTts = _showMissingEnglishTtsNotice;

      // Listen for live widget deep links (`lexora://word/<encodedKey>`).
      _widgetClickSub = HomeWidget.widgetClicked.listen(_handleWidgetDeepLink);

      // Start idempotent bootstrap sequence.
      ref.read(bootstrapControllerProvider.notifier).start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_widgetClickSub?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(ref.read(audioServiceProvider).onAppLifecycleChanged(state));
  }

  void _handleWidgetDeepLink(Uri? uri) {
    final wordKey = AppBootstrap.parseWordDeepLink(uri);
    if (wordKey == null) return;

    final boot = ref.read(bootstrapControllerProvider);
    if (boot.stage != BootstrapStage.ready) {
      ref.read(bootstrapControllerProvider.notifier).setPendingDeepLink(wordKey);
      return;
    }
    if (!boot.placementCompleted) return;

    final encoded = Uri.encodeComponent(wordKey);
    ref.read(appRouterProvider).push('/word/$encoded?depth=2');
  }

  void _showMissingEnglishTtsNotice() {
    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: const Text(
            'Çevrimdışı İngilizce TTS ses paketi bulunamadı. Sistem TTS ayarlarından İngilizce paket indirebilirsin.',
          ),
          action: SnackBarAction(
            label: 'TTS Ayarları',
            onPressed: () {
              ref.read(dictExtractorServiceProvider).openTtsSettings();
            },
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final settings = ref.watch(settingsControllerProvider);

    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      themeMode: settings.themeMode,
      theme: LexoraTheme.lightTheme(),
      darkTheme: LexoraTheme.darkTheme(),
      routerConfig: router,
    );
  }
}
