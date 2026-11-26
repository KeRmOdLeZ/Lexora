import 'dart:convert';
import 'dart:math';

import 'package:home_widget/home_widget.dart';
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import '../core/date_utils.dart';
import '../models/word_entry.dart';
import 'database_service.dart';

/// Synchronizes Lexora's 2x2 dark home screen widget using strictly 5 String keys.
class WidgetSyncService {
  static const String _androidProviderName = 'VocabWidgetProvider';

  /// Pushes current or rotated word to the home widget from the main isolate.
  static Future<void> syncFromApp(
    DatabaseService db, {
    bool forceRotate = false,
  }) async {
    try {
      final placementDone =
          await db.getMeta(AppMetaKeys.placementCompleted) == 'true';
      if (!placementDone) {
        await _writeSetupPendingPayload();
        return;
      }

      final accent = await db.getMeta(AppMetaKeys.defaultAccent, fallback: 'us');
      final currentKey = await db.getMeta(AppMetaKeys.currentWidgetWordKey);
      final targetLevel =
          await db.getMeta(AppMetaKeys.targetStartLevel, fallback: 'B1');

      WordEntry? chosen;
      if (!forceRotate && currentKey.isNotEmpty) {
        chosen = await db.getWordByKey(currentKey);
      }

      chosen ??= await _pickNextWordFromApp(
        db,
        excludeKey: currentKey,
        targetLevel: targetLevel,
      );

      if (chosen == null) {
        await _writeSetupPendingPayload();
        return;
      }

      await _writeWordPayload(chosen, accent: accent);
      await db.setMetaBatch({
        AppMetaKeys.currentWidgetWordKey: chosen.wordKey,
        AppMetaKeys.widgetLastUpdatedMs:
            DateTime.now().millisecondsSinceEpoch.toString(),
      });
    } catch (e) {
      lexoraLog('Widget sync error: $e');
    }
  }

  /// Background isolate variant (`workmanager` / `home_widget` refresh button).
  static Future<void> rotateInBackground({
    required Database userDb,
    required Database dictDb,
    required bool isManualRefresh,
  }) async {
    final active =
        (await HomeWidget.getWidgetData<bool>(WidgetDataKeys.widgetActive)) ??
            false;
    if (!active && !isManualRefresh) {
      return;
    }

    final meta = await _readMetaMap(userDb);
    if (meta[AppMetaKeys.placementCompleted] != 'true') {
      await _writeSetupPendingPayload();
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastUpdatedMs =
        int.tryParse(meta[AppMetaKeys.widgetLastUpdatedMs] ?? '0') ?? 0;

    if (isManualRefresh) {
      // 1-second rate limit on manual `↻` button taps.
      if (nowMs - lastUpdatedMs < AppConstants.widgetManualRefreshCooldownMs) {
        return;
      }
    } else {
      // Automatic rotation with 15-minute Doze tolerance (`intervalMs - 900_000`).
      final intervalHours =
          int.tryParse(meta[AppMetaKeys.widgetIntervalHours] ?? '6') ?? 6;
      final intervalMs = intervalHours * 60 * 60 * 1000;
      final thresholdMs = max(0, intervalMs - AppConstants.widgetDozeToleranceMs);
      if (lastUpdatedMs > 0 && (nowMs - lastUpdatedMs) < thresholdMs) {
        return;
      }
    }

    final currentKey = meta[AppMetaKeys.currentWidgetWordKey] ?? '';
    final accent = meta[AppMetaKeys.defaultAccent] ?? 'us';
    final targetLevel = meta[AppMetaKeys.targetStartLevel] ?? 'B1';

    final chosen = await _pickNextWordRaw(
      userDb: userDb,
      dictDb: dictDb,
      excludeKey: currentKey,
      targetLevel: targetLevel,
    );
    if (chosen == null) return;

    await _writeWordPayload(chosen, accent: accent);
    await userDb.transaction((txn) async {
      await txn.insert(
        'app_meta',
        {'key': AppMetaKeys.currentWidgetWordKey, 'value': chosen.wordKey},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'app_meta',
        {'key': AppMetaKeys.widgetLastUpdatedMs, 'value': '$nowMs'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<WordEntry?> _pickNextWordFromApp(
    DatabaseService db, {
    required String excludeKey,
    required String targetLevel,
  }) async {
    final rng = Random();
    final today = LexoraDateUtils.todayLocalKey();
    final session = await db.getDailySession(today);

    final candidates = <String>{
      ...?session?.morningWordKeys,
      ...?session?.newWordKeys,
    }.toList();

    if (candidates.length > 1) {
      candidates.remove(excludeKey);
    }

    if (candidates.isNotEmpty) {
      final pickKey = candidates[rng.nextInt(candidates.length)];
      final entry = await db.getWordByKey(pickKey);
      if (entry != null) return entry;
    }

    final pool = await db.getStudyPoolKeysByLevel(targetLevel);
    final filtered = pool.where((k) => k != excludeKey).toList();
    if (filtered.isNotEmpty) {
      final key = filtered[rng.nextInt(filtered.length)];
      return db.getWordByKey(key);
    }

    final fallback = await db.getPopularBrowseWords(limit: 20);
    if (fallback.isEmpty) return null;
    return fallback[rng.nextInt(fallback.length)];
  }

  static Future<WordEntry?> _pickNextWordRaw({
    required Database userDb,
    required Database dictDb,
    required String excludeKey,
    required String targetLevel,
  }) async {
    final rng = Random();
    final today = LexoraDateUtils.todayLocalKey();

    final sessionRows = await userDb.query(
      'daily_session',
      columns: ['morning_word_keys', 'new_word_keys'],
      where: 'session_date = ?',
      whereArgs: [today],
      limit: 1,
    );
    final candidates = <String>{};
    if (sessionRows.isNotEmpty) {
      for (final col in ['morning_word_keys', 'new_word_keys']) {
        final raw = sessionRows.first[col] as String?;
        if (raw != null && raw.isNotEmpty) {
          try {
            final list = jsonDecode(raw) as List;
            for (final item in list) {
              candidates.add(item.toString());
            }
          } catch (_) {}
        }
      }
    }

    if (candidates.length > 1) {
      candidates.remove(excludeKey);
    }
    if (candidates.isNotEmpty) {
      final list = candidates.toList();
      final key = list[rng.nextInt(list.length)];
      final rows = await dictDb.query(
        'words',
        where: 'word_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isNotEmpty) return WordEntry.fromMap(rows.first);
    }

    final poolRows = await dictDb.rawQuery(
      'SELECT word_key FROM words WHERE level = ? AND cloze_example IS NOT NULL LIMIT 200',
      [targetLevel],
    );
    final keys = poolRows
        .map((r) => r['word_key'] as String)
        .where((k) => k != excludeKey)
        .toList();
    if (keys.isEmpty) return null;
    final chosenKey = keys[rng.nextInt(keys.length)];
    final chosenRows = await dictDb.query(
      'words',
      where: 'word_key = ?',
      whereArgs: [chosenKey],
      limit: 1,
    );
    return chosenRows.isEmpty ? null : WordEntry.fromMap(chosenRows.first);
  }

  static Future<void> _writeSetupPendingPayload() async {
    await HomeWidget.saveWidgetData<String>(WidgetDataKeys.wordKey, '');
    await HomeWidget.saveWidgetData<String>(WidgetDataKeys.wordDisplay, 'Lexora');
    await HomeWidget.saveWidgetData<String>(WidgetDataKeys.level, '');
    await HomeWidget.saveWidgetData<String>(WidgetDataKeys.ipa, '');
    await HomeWidget.saveWidgetData<String>(
      WidgetDataKeys.meaning,
      'Kurulumu tamamlamak için dokun',
    );
    await HomeWidget.updateWidget(androidName: _androidProviderName);
  }

  static Future<void> _writeWordPayload(
    WordEntry entry, {
    required String accent,
  }) async {
    await HomeWidget.saveWidgetData<String>(WidgetDataKeys.wordKey, entry.wordKey);
    await HomeWidget.saveWidgetData<String>(
      WidgetDataKeys.wordDisplay,
      entry.wordDisplay,
    );
    await HomeWidget.saveWidgetData<String>(
      WidgetDataKeys.level,
      entry.level ?? '',
    );
    await HomeWidget.saveWidgetData<String>(
      WidgetDataKeys.ipa,
      entry.ipaForAccent(accent) ?? '',
    );
    await HomeWidget.saveWidgetData<String>(
      WidgetDataKeys.meaning,
      entry.meaningEn,
    );
    await HomeWidget.updateWidget(androidName: _androidProviderName);
  }

  static Future<Map<String, String>> _readMetaMap(Database userDb) async {
    final rows = await userDb.query('app_meta');
    final map = Map<String, String>.from(AppMetaKeys.defaults);
    for (final row in rows) {
      map[row['key'] as String] = row['value'] as String;
    }
    return map;
  }
}
