import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants.dart';
import '../models/word_entry.dart';
import '../services/app_bootstrap.dart';
import '../services/audio_service.dart';
import '../services/backup_service.dart';
import '../services/database_service.dart';
import '../services/dict_extractor_service.dart';
import '../services/notification_service.dart';
import '../services/widget_sync_service.dart';

// -----------------------------------------------------------------------------
// Core service singletons
// -----------------------------------------------------------------------------

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  final svc = DatabaseService();
  ref.onDispose(() {
    unawaited(svc.closeAll());
  });
  return svc;
});

final dictExtractorServiceProvider = Provider<DictExtractorService>((ref) {
  return DictExtractorService();
});

final audioServiceProvider = Provider<AudioService>((ref) {
  final db = ref.watch(databaseServiceProvider);
  final svc = AudioService(databaseService: db);
  ref.onDispose(() {
    unawaited(svc.dispose());
  });
  return svc;
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.watch(databaseServiceProvider));
});

final appBootstrapServiceProvider = Provider<AppBootstrap>((ref) {
  return AppBootstrap(
    databaseService: ref.watch(databaseServiceProvider),
    extractorService: ref.watch(dictExtractorServiceProvider),
  );
});

final audioPlaybackStateProvider = StreamProvider<AudioPlaybackState>((ref) {
  final svc = ref.watch(audioServiceProvider);
  return svc.playbackStateStream;
});

// -----------------------------------------------------------------------------
// Bootstrap controller
// -----------------------------------------------------------------------------

class BootstrapController extends StateNotifier<BootstrapState> {
  BootstrapController(this._bootstrap, this._ref) : super(const BootstrapState());

  final AppBootstrap _bootstrap;
  final Ref _ref;

  Future<void> start() async {
    final finalState = await _bootstrap.run(
      onProgress: (next) {
        if (mounted) state = next;
      },
    );
    if (finalState.stage == BootstrapStage.ready) {
      await _ref.read(settingsControllerProvider.notifier).reload();
      await _ref.read(dashboardControllerProvider.notifier).refresh();
    }
  }

  void markPlacementCompleted() {
    state = state.copyWith(placementCompleted: true);
  }

  void setPendingDeepLink(String wordKey) {
    state = state.copyWith(pendingDeepLinkWordKey: wordKey);
  }

  String? consumePendingDeepLink() {
    final key = state.pendingDeepLinkWordKey;
    if (key != null) {
      state = state.copyWith(clearPendingDeepLink: true);
    }
    return key;
  }
}

final bootstrapControllerProvider =
    StateNotifierProvider<BootstrapController, BootstrapState>((ref) {
  return BootstrapController(
    ref.watch(appBootstrapServiceProvider),
    ref,
  );
});

// -----------------------------------------------------------------------------
// Settings & Theme controller
// -----------------------------------------------------------------------------

class AppSettingsState {
  const AppSettingsState({
    this.defaultAccent = 'us',
    this.autoPlayAudio = true,
    this.widgetIntervalHours = 6,
    this.targetStartLevel = 'B1',
    this.themeMode = ThemeMode.dark,
    this.morningReminder = '09:00',
    this.eveningReminder = '20:00',
    this.audioCacheBytes = 0,
    this.currentStreak = 0,
    this.longestStreak = 0,
  });

  final String defaultAccent;
  final bool autoPlayAudio;
  final int widgetIntervalHours;
  final String targetStartLevel;
  final ThemeMode themeMode;
  final String morningReminder;
  final String eveningReminder;
  final int audioCacheBytes;
  final int currentStreak;
  final int longestStreak;

  AppSettingsState copyWith({
    String? defaultAccent,
    bool? autoPlayAudio,
    int? widgetIntervalHours,
    String? targetStartLevel,
    ThemeMode? themeMode,
    String? morningReminder,
    String? eveningReminder,
    int? audioCacheBytes,
    int? currentStreak,
    int? longestStreak,
  }) {
    return AppSettingsState(
      defaultAccent: defaultAccent ?? this.defaultAccent,
      autoPlayAudio: autoPlayAudio ?? this.autoPlayAudio,
      widgetIntervalHours: widgetIntervalHours ?? this.widgetIntervalHours,
      targetStartLevel: targetStartLevel ?? this.targetStartLevel,
      themeMode: themeMode ?? this.themeMode,
      morningReminder: morningReminder ?? this.morningReminder,
      eveningReminder: eveningReminder ?? this.eveningReminder,
      audioCacheBytes: audioCacheBytes ?? this.audioCacheBytes,
      currentStreak: currentStreak ?? this.currentStreak,
      longestStreak: longestStreak ?? this.longestStreak,
    );
  }
}

class SettingsController extends StateNotifier<AppSettingsState> {
  SettingsController(this._db, this._audio) : super(const AppSettingsState());

  final DatabaseService _db;
  final AudioService _audio;

  Future<void> reload() async {
    if (!_db.isUserDbOpen) return;
    final meta = await _db.getAllMeta();
    final cacheBytes = await _db.getTotalMediaCacheBytes();

    final modeStr = meta[AppMetaKeys.themeMode] ?? 'dark';
    final themeMode = switch (modeStr) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };

    state = AppSettingsState(
      defaultAccent: meta[AppMetaKeys.defaultAccent] == 'uk' ? 'uk' : 'us',
      autoPlayAudio: meta[AppMetaKeys.autoPlayAudio] != 'false',
      widgetIntervalHours:
          int.tryParse(meta[AppMetaKeys.widgetIntervalHours] ?? '6') ?? 6,
      targetStartLevel: meta[AppMetaKeys.targetStartLevel] ?? 'B1',
      themeMode: themeMode,
      morningReminder: meta[AppMetaKeys.morningReminder] ?? '09:00',
      eveningReminder: meta[AppMetaKeys.eveningReminder] ?? '20:00',
      audioCacheBytes: cacheBytes,
      currentStreak: int.tryParse(meta[AppMetaKeys.currentStreak] ?? '0') ?? 0,
      longestStreak: int.tryParse(meta[AppMetaKeys.longestStreak] ?? '0') ?? 0,
    );
  }

  Future<void> setDefaultAccent(String accent) async {
    final norm = accent == 'uk' ? 'uk' : 'us';
    await _db.setMeta(AppMetaKeys.defaultAccent, norm);
    state = state.copyWith(defaultAccent: norm);
    await WidgetSyncService.syncFromApp(_db);
  }

  Future<void> setAutoPlayAudio(bool enabled) async {
    await _db.setMeta(AppMetaKeys.autoPlayAudio, enabled ? 'true' : 'false');
    state = state.copyWith(autoPlayAudio: enabled);
  }

  Future<void> setWidgetIntervalHours(int hours) async {
    final valid = (hours == 6 || hours == 12 || hours == 24) ? hours : 6;
    await _db.setMeta(AppMetaKeys.widgetIntervalHours, valid.toString());
    state = state.copyWith(widgetIntervalHours: valid);
    try {
      await Workmanager().registerPeriodicTask(
        AppConstants.workTaskWidgetRotate,
        AppConstants.workTaskWidgetRotate,
        frequency: Duration(hours: valid),
        initialDelay: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
          requiresBatteryNotLow: false,
        ),
      );
    } catch (e) {
      lexoraLog('Reschedule widget task error: $e');
    }
  }

  Future<void> setTargetStartLevel(String level) async {
    if (!AppConstants.studyCefrLevels.contains(level)) return;
    await _db.setMeta(AppMetaKeys.targetStartLevel, level);
    state = state.copyWith(targetStartLevel: level);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final str = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    };
    await _db.setMeta(AppMetaKeys.themeMode, str);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setMorningReminder(String value) async {
    if (value != 'off') {
      try {
        await NotificationService.requestPermissionIfNeeded();
      } catch (e) {
        lexoraLog('Morning reminder permission error: $e');
      }
    }
    await _db.setMeta(AppMetaKeys.morningReminder, value);
    state = state.copyWith(morningReminder: value);
    try {
      await NotificationService.syncSevenDaySchedule(_db);
    } catch (e) {
      lexoraLog('Morning reminder schedule error: $e');
    }
  }

  Future<void> setEveningReminder(String value) async {
    if (value != 'off') {
      try {
        await NotificationService.requestPermissionIfNeeded();
      } catch (e) {
        lexoraLog('Evening reminder permission error: $e');
      }
    }
    await _db.setMeta(AppMetaKeys.eveningReminder, value);
    state = state.copyWith(eveningReminder: value);
    try {
      await NotificationService.syncSevenDaySchedule(_db);
    } catch (e) {
      lexoraLog('Evening reminder schedule error: $e');
    }
  }

  Future<void> clearAudioCache() async {
    await _audio.clearAllAudioCache();
    state = state.copyWith(audioCacheBytes: 0);
  }

  Future<void> refreshCacheSize() async {
    if (!_db.isUserDbOpen) return;
    final bytes = await _db.getTotalMediaCacheBytes();
    state = state.copyWith(audioCacheBytes: bytes);
  }
}

final settingsControllerProvider =
    StateNotifierProvider<SettingsController, AppSettingsState>((ref) {
  return SettingsController(
    ref.watch(databaseServiceProvider),
    ref.watch(audioServiceProvider),
  );
});

// -----------------------------------------------------------------------------
// Dashboard controller
// -----------------------------------------------------------------------------

class DashboardState {
  const DashboardState({
    this.isLoading = true,
    this.session,
    this.masteryCounts = const MasteryCounts(
      learning: 0,
      consolidating: 0,
      mastered: 0,
    ),
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.targetStartLevel = 'B1',
  });

  final bool isLoading;
  final DailySession? session;
  final MasteryCounts masteryCounts;
  final int currentStreak;
  final int longestStreak;
  final String targetStartLevel;
}

class DashboardController extends StateNotifier<DashboardState> {
  DashboardController(this._db) : super(const DashboardState());

  final DatabaseService _db;

  Future<void> refresh() async {
    if (!_db.isUserDbOpen || !_db.isDictDbOpen) return;
    final session = await _db.getOrCreateTodaySession();
    final counts = await _db.getMasteryCounts();
    final meta = await _db.getAllMeta();

    state = DashboardState(
      isLoading: false,
      session: session,
      masteryCounts: counts,
      currentStreak: int.tryParse(meta[AppMetaKeys.currentStreak] ?? '0') ?? 0,
      longestStreak: int.tryParse(meta[AppMetaKeys.longestStreak] ?? '0') ?? 0,
      targetStartLevel: meta[AppMetaKeys.targetStartLevel] ?? 'B1',
    );
  }
}

final dashboardControllerProvider =
    StateNotifierProvider<DashboardController, DashboardState>((ref) {
  return DashboardController(ref.watch(databaseServiceProvider));
});
