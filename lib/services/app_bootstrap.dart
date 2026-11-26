import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart' hide callbackDispatcher;
import 'package:workmanager/workmanager.dart';

import '../core/constants.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';
import 'background_tasks.dart';
import 'backup_service.dart';
import 'database_service.dart';
import 'dict_extractor_service.dart';
import 'notification_service.dart';
import 'widget_sync_service.dart';

enum BootstrapStage {
  starting,
  extractingDictionary,
  openingDictionary,
  ready,
  error,
}

class BootstrapState {
  const BootstrapState({
    this.stage = BootstrapStage.starting,
    this.progress = 0.0,
    this.statusMessage = 'Lexora hazırlanıyor...',
    this.errorMessage,
    this.isInsufficientStorage = false,
    this.placementCompleted = false,
    this.dictMetadata,
    this.pendingDeepLinkWordKey,
  });

  final BootstrapStage stage;
  final double progress;
  final String statusMessage;
  final String? errorMessage;
  final bool isInsufficientStorage;
  final bool placementCompleted;
  final DictMetadata? dictMetadata;
  final String? pendingDeepLinkWordKey;

  BootstrapState copyWith({
    BootstrapStage? stage,
    double? progress,
    String? statusMessage,
    String? errorMessage,
    bool? isInsufficientStorage,
    bool? placementCompleted,
    DictMetadata? dictMetadata,
    String? pendingDeepLinkWordKey,
    bool clearPendingDeepLink = false,
  }) {
    return BootstrapState(
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      errorMessage: errorMessage,
      isInsufficientStorage: isInsufficientStorage ?? this.isInsufficientStorage,
      placementCompleted: placementCompleted ?? this.placementCompleted,
      dictMetadata: dictMetadata ?? this.dictMetadata,
      pendingDeepLinkWordKey: clearPendingDeepLink
          ? null
          : (pendingDeepLinkWordKey ?? this.pendingDeepLinkWordKey),
    );
  }
}

/// Idempotent application bootstrap pipeline executing steps 1..6 sequentially.
class AppBootstrap {
  AppBootstrap({
    required DatabaseService databaseService,
    required DictExtractorService extractorService,
  })  : _db = databaseService,
        _extractor = extractorService;

  final DatabaseService _db;
  final DictExtractorService _extractor;

  Future<BootstrapState>? _inFlightRun;

  /// Parses `lexora://word/<encodedKey>` into a normalized `word_key`, or `null`.
  static String? parseWordDeepLink(Uri? uri) {
    if (uri == null || uri.scheme != AppConstants.deepLinkScheme) return null;
    if (uri.host != 'word') return null;
    if (uri.pathSegments.isEmpty) return null;
    try {
      // Uri.pathSegments already decodes UTF-8 percent-encoding safely.
      final segment = uri.pathSegments.first;
      final normalized = TextNormalizer.normalizeQuery(segment);
      if (normalized.isEmpty || normalized.length > 64) return null;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  /// Runs the 6-step idempotent bootstrap sequence.
  Future<BootstrapState> run({
    required void Function(BootstrapState state) onProgress,
  }) {
    return _inFlightRun ??= _runInternal(onProgress).whenComplete(() {
      _inFlightRun = null;
    });
  }

  Future<BootstrapState> _runInternal(
    void Function(BootstrapState state) onProgress,
  ) async {
    StreamSubscription<double>? progressSub;
    try {
      onProgress(
        const BootstrapState(
          stage: BootstrapStage.starting,
          progress: 0.05,
          statusMessage: 'Kullanıcı veritabanı açılıyor...',
        ),
      );

      // 1) Open user_data.db
      await _db.openUserDb();

      // 2) Compare bundled meta.json uncompressed_sha256 with app_meta.dict_signature
      final meta = await _extractor.loadAssetMetadata();
      final storedSignature = await _db.getMeta(AppMetaKeys.dictSignature);
      final storedSchema = await _db.getMeta(AppMetaKeys.dictSchemaVersion);
      final storedReady = await _db.getMeta(AppMetaKeys.dictReady);
      final dictPath = await _extractor.getDictDbPath();
      final dictExists = File(dictPath).existsSync();
      final tmpExists = File('$dictPath.tmp').existsSync();

      final needsExtraction = !dictExists ||
          tmpExists ||
          storedReady != '1' ||
          storedSchema != AppConstants.dictSchemaVersion ||
          storedSignature != meta.uncompressedSha256;

      if (needsExtraction) {
        await _db.closeDictDb();
        await _db.setMeta(AppMetaKeys.dictReady, '0');

        onProgress(
          BootstrapState(
            stage: BootstrapStage.extractingDictionary,
            progress: 0.08,
            statusMessage: 'Çevrimdışı sözlük hazırlanıyor...',
            dictMetadata: meta,
          ),
        );

        progressSub = _extractor.progressStream.listen((pct) {
          onProgress(
            BootstrapState(
              stage: BootstrapStage.extractingDictionary,
              progress: (0.08 + pct * 0.80).clamp(0.08, 0.90),
              statusMessage:
                  'Çevrimdışı sözlük kuruluyor... %${(pct * 100).round()}',
              dictMetadata: meta,
            ),
          );
        });

        await _extractor.extractDict();
        await progressSub.cancel();
        progressSub = null;

        // Single atomic transaction committing dict_signature, schema_version=2, dict_ready=1
        await _db.setMetaBatch({
          AppMetaKeys.dictSignature: meta.uncompressedSha256,
          AppMetaKeys.dictSchemaVersion: AppConstants.dictSchemaVersion,
          AppMetaKeys.dictReady: '1',
        });
      }

      // 3) Open read-only vocab_dict.db
      onProgress(
        BootstrapState(
          stage: BootstrapStage.openingDictionary,
          progress: 0.92,
          statusMessage: 'Sözlük indeksi yükleniyor...',
          dictMetadata: meta,
        ),
      );
      await _db.openDictDb(dictPath);

      // 4) Cleanup temporary exports older than 1 hour
      await BackupService.cleanupStaleExports();

      // 5) Initialize WorkManager + HomeWidget background callback + 7-day notifications + widget sync
      await _registerBackgroundServices();
      try {
        await NotificationService.syncSevenDaySchedule(_db);
      } catch (e) {
        lexoraLog('Notification schedule sync error: $e');
      }
      await WidgetSyncService.syncFromApp(_db);

      // 6) Inspect initial pending deep link (honoring placement_completed == 'true')
      final placementCompleted =
          await _db.getMeta(AppMetaKeys.placementCompleted) == 'true';
      String? pendingWordKey;
      if (placementCompleted) {
        try {
          final initialUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
          pendingWordKey = parseWordDeepLink(initialUri);
        } catch (e) {
          lexoraLog('Initial deep link check error: $e');
        }
      }

      final readyState = BootstrapState(
        stage: BootstrapStage.ready,
        progress: 1.0,
        statusMessage: 'Hazır',
        placementCompleted: placementCompleted,
        dictMetadata: meta,
        pendingDeepLinkWordKey: pendingWordKey,
      );
      onProgress(readyState);
      return readyState;
    } on PlatformException catch (e) {
      final isStorage = e.code == 'INSUFFICIENT_STORAGE';
      final errState = BootstrapState(
        stage: BootstrapStage.error,
        progress: 0.0,
        statusMessage: isStorage
            ? 'Yetersiz depolama alanı'
            : 'Sözlük kurulumu tamamlanamadı',
        errorMessage: isStorage
            ? 'Sözlüğü kurmak için cihazınızda yeterli boş alan bulunmuyor. Lütfen yer açıp tekrar deneyin.'
            : (e.message ?? 'Beklenmeyen kurulum hatası.'),
        isInsufficientStorage: isStorage,
      );
      onProgress(errState);
      return errState;
    } catch (e) {
      final errState = BootstrapState(
        stage: BootstrapStage.error,
        progress: 0.0,
        statusMessage: 'Başlatma hatası',
        errorMessage: e.toString(),
      );
      onProgress(errState);
      return errState;
    } finally {
      await progressSub?.cancel();
    }
  }

  Future<void> _registerBackgroundServices() async {
    try {
      await HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);
    } catch (e) {
      lexoraLog('HomeWidget.registerInteractivityCallback error: $e');
    }

    try {
      await Workmanager().initialize(callbackDispatcher);

      final intervalHours = int.tryParse(
            await _db.getMeta(AppMetaKeys.widgetIntervalHours, fallback: '6'),
          ) ??
          6;

      await Workmanager().registerPeriodicTask(
        AppConstants.workTaskWidgetRotate,
        AppConstants.workTaskWidgetRotate,
        frequency: Duration(hours: intervalHours.clamp(1, 24)),
        initialDelay: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
          requiresBatteryNotLow: false,
        ),
      );

      await Workmanager().registerPeriodicTask(
        AppConstants.workTaskAudioCache,
        AppConstants.workTaskAudioCache,
        frequency: const Duration(hours: 24),
        initialDelay: const Duration(hours: 1),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(
          networkType: NetworkType.unmetered,
          requiresBatteryNotLow: true,
        ),
      );
    } catch (e) {
      lexoraLog('WorkManager registration error: $e');
    }
  }
}
