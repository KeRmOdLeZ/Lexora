import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants.dart';
import '../core/date_utils.dart';
import '../models/word_entry.dart';
import 'audio_service.dart';
import 'audio_validator.dart';
import 'database_service.dart';
import 'notification_service.dart';
import 'widget_sync_service.dart';

/// Top-level WorkManager entry point (separate file, guaranteed AOT preservation).
@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  Workmanager().executeTask((taskName, inputData) async {
    Database? userDb;
    Database? dictDb;
    try {
      userDb = await DatabaseService.openUserDbForBackground();

      if (taskName == AppConstants.workTaskWidgetRotate) {
        // Refill 7-day rolling notifications BEFORE any widget early exit if > 3 days old.
        try {
          await NotificationService.refillSevenDayScheduleInBackground(userDb);
        } catch (e) {
          lexoraLog('Background notification refill error: $e');
        }

        dictDb = await DatabaseService.openDictDbForBackground(userDb);
        if (dictDb == null) return true;

        await WidgetSyncService.rotateInBackground(
          userDb: userDb,
          dictDb: dictDb,
          isManualRefresh: false,
        );
        return true;
      }

      if (taskName == AppConstants.workTaskAudioCache) {
        dictDb = await DatabaseService.openDictDbForBackground(userDb);
        if (dictDb == null) return true;

        await _runAudioCacheMaintenance(userDb: userDb, dictDb: dictDb);
        return true;
      }

      return true;
    } catch (e) {
      lexoraLog('Background WorkManager task "$taskName" error: $e');
      return true;
    } finally {
      try {
        await dictDb?.close();
      } catch (_) {}
      try {
        await userDb?.close();
      } catch (_) {}
    }
  });
}

/// Top-level HomeWidget interactive callback for the `↻` refresh button (`lexora://refresh`).
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  if (uri == null || uri.scheme != AppConstants.deepLinkScheme || uri.host != 'refresh') {
    return;
  }

  Database? userDb;
  Database? dictDb;
  try {
    userDb = await DatabaseService.openUserDbForBackground();
    dictDb = await DatabaseService.openDictDbForBackground(userDb);
    if (dictDb == null) return;

    await WidgetSyncService.rotateInBackground(
      userDb: userDb,
      dictDb: dictDb,
      isManualRefresh: true,
    );
  } catch (e) {
    lexoraLog('widgetBackgroundCallback error: $e');
  } finally {
    try {
      await dictDb?.close();
    } catch (_) {}
    try {
      await userDb?.close();
    } catch (_) {}
  }
}

/// Prunes orphan `media_cache` entries and pre-caches tomorrow's review/study audio files
/// on unmetered Wi-Fi when battery is not low.
Future<void> _runAudioCacheMaintenance({
  required Database userDb,
  required Database dictDb,
}) async {
  final supportDir = await getApplicationSupportDirectory();
  final cacheDir = Directory(p.join(supportDir.path, 'audio_cache'));
  if (!await cacheDir.exists()) {
    await cacheDir.create(recursive: true);
  }

  // 1) Delete orphan media_cache rows whose physical file no longer exists or is invalid.
  final cachedRows = await userDb.query('media_cache');
  for (final row in cachedRows) {
    final wk = row['word_key'] as String;
    final accent = row['accent'] as String;
    final fileName = row['file_name'] as String;
    final file = File(p.join(cacheDir.path, fileName));
    if (!AudioValidator.isValidCacheFileName(fileName) || !file.existsSync()) {
      await userDb.delete(
        'media_cache',
        where: 'word_key = ? AND accent = ?',
        whereArgs: [wk, accent],
      );
    }
  }

  // 2) Pre-cache tomorrow's due reviews + today's active words in user's preferred accent.
  final metaRows = await userDb.query(
    'app_meta',
    where: 'key IN (?, ?)',
    whereArgs: [AppMetaKeys.defaultAccent, AppMetaKeys.placementCompleted],
  );
  var accent = 'us';
  var placementDone = false;
  for (final r in metaRows) {
    if (r['key'] == AppMetaKeys.defaultAccent) accent = r['value'] as String;
    if (r['key'] == AppMetaKeys.placementCompleted) {
      placementDone = (r['value'] as String) == 'true';
    }
  }
  if (!placementDone) return;

  final today = LexoraDateUtils.todayLocalKey();
  final tomorrow = LexoraDateUtils.addDaysToDateKey(today, 1);

  final dueRows = await userDb.rawQuery(
    '''
    SELECT word_key FROM user_progress
    WHERE next_review_date <= ?
    ORDER BY next_review_date ASC, score ASC
    LIMIT 15
    ''',
    [tomorrow],
  );
  final candidateKeys = <String>{
    for (final r in dueRows) r['word_key'] as String,
  };

  final sessionRows = await userDb.query(
    'daily_session',
    columns: ['morning_word_keys'],
    where: 'session_date = ?',
    whereArgs: [today],
    limit: 1,
  );
  if (sessionRows.isNotEmpty) {
    try {
      final list = jsonDecode(sessionRows.first['morning_word_keys'] as String) as List;
      for (final k in list) {
        candidateKeys.add(k.toString());
      }
    } catch (_) {}
  }

  if (candidateKeys.isEmpty) return;

  final keyList = candidateKeys.toList(growable: false);
  final words = <WordEntry>[];
  for (final chunk in DatabaseService.chunkList(keyList)) {
    final placeholders = List.filled(chunk.length, '?').join(',');
    final rows = await dictDb.rawQuery(
      'SELECT * FROM words WHERE word_key IN ($placeholders)',
      chunk,
    );
    words.addAll(rows.map(WordEntry.fromMap));
  }

  // Reuse AudioService download security pipeline with isolated DB handles.
  final bgDbService = DatabaseService();
  await bgDbService.openUserDb();
  final audioService = AudioService(databaseService: bgDbService);
  try {
    for (final entry in words.take(15)) {
      await audioService.preCacheWordAudio(entry, accent: accent);
    }
  } finally {
    await audioService.dispose();
    await bgDbService.closeAll();
  }
}
