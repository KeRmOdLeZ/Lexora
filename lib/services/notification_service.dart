import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../core/constants.dart';
import '../core/date_utils.dart';
import 'database_service.dart';

/// 7-day rolling reminder scheduler (Morning IDs 100..106, Evening IDs 200..206).
/// Never uses `matchDateTimeComponents` and never requires `SCHEDULE_EXACT_ALARM`.
/// Every entry point is defensively isolated with `try/catch` so notification
/// errors never block study progress, session completion, or app startup.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const String _channelId = 'lexora_daily_study';
  static const String _channelName = 'Günlük Çalışma Hatırlatıcıları';
  static const String _channelDesc = 'Sabah ve akşam kelime oturumu bildirimleri';

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      tz_data.initializeTimeZones();
      try {
        final tzName = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(tzName));
      } catch (e) {
        lexoraLog('Timezone fallback to UTC: $e');
        tz.setLocalLocation(tz.UTC);
      }

      const androidInit = AndroidInitializationSettings('ic_stat_notify');
      const initSettings = InitializationSettings(android: androidInit);
      await _plugin.initialize(initSettings);
      _initialized = true;
    } catch (e) {
      lexoraLog('NotificationService.initialize error: $e');
    }
  }

  static Future<bool> requestPermissionIfNeeded() async {
    try {
      await initialize();
      if (!_initialized) return false;
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl == null) return false;
      final granted = await androidImpl.requestNotificationsPermission();
      return granted ?? false;
    } catch (e) {
      lexoraLog('NotificationService.requestPermissionIfNeeded error: $e');
      return false;
    }
  }

  /// Reschedules the 7-day rolling window using live `DatabaseService`.
  static Future<void> syncSevenDaySchedule(DatabaseService db) async {
    try {
      await initialize();
      if (!_initialized) return;
      final morningTime =
          await db.getMeta(AppMetaKeys.morningReminder, fallback: '09:00');
      final eveningTime =
          await db.getMeta(AppMetaKeys.eveningReminder, fallback: '20:00');
      final placementDone =
          await db.getMeta(AppMetaKeys.placementCompleted) == 'true';

      final todayKey = LexoraDateUtils.todayLocalKey();
      final todaySession = await db.getDailySession(todayKey);

      await _scheduleWindow(
        morningTime: morningTime,
        eveningTime: eveningTime,
        placementDone: placementDone,
        skipTodayMorning: todaySession?.morningCompleted ?? false,
        skipTodayEvening: (todaySession?.eveningCompleted ?? false) ||
            (todaySession?.isReviewOnly ?? false),
      );
      await db.setMeta(AppMetaKeys.lastNotifRefillDate, todayKey);
    } catch (e) {
      lexoraLog('NotificationService.syncSevenDaySchedule error: $e');
    }
  }

  /// Background-isolate variant using a `singleInstance: false` `user_data.db`.
  static Future<void> refillSevenDayScheduleInBackground(Database userDb) async {
    try {
      await initialize();
      if (!_initialized) return;
      final rows = await userDb.query(
        'app_meta',
        where: 'key IN (?, ?, ?, ?)',
        whereArgs: [
          AppMetaKeys.morningReminder,
          AppMetaKeys.eveningReminder,
          AppMetaKeys.placementCompleted,
          AppMetaKeys.lastNotifRefillDate,
        ],
      );
      final meta = <String, String>{};
      for (final r in rows) {
        meta[r['key'] as String] = r['value'] as String;
      }

      final todayKey = LexoraDateUtils.todayLocalKey();
      final lastRefill = meta[AppMetaKeys.lastNotifRefillDate] ?? '';
      if (lastRefill.isNotEmpty &&
          LexoraDateUtils.parseDateKeyStrict(lastRefill) != null) {
        final diff = LexoraDateUtils.daysBetweenDateKeys(lastRefill, todayKey);
        if (diff <= AppConstants.notifRefillThresholdDays) {
          return;
        }
      }

      final sessionRows = await userDb.query(
        'daily_session',
        columns: ['morning_completed', 'evening_completed', 'is_review_only'],
        where: 'session_date = ?',
        whereArgs: [todayKey],
        limit: 1,
      );
      final skipMorning = sessionRows.isNotEmpty &&
          (sessionRows.first['morning_completed'] as int) != 0;
      final skipEvening = sessionRows.isNotEmpty &&
          (((sessionRows.first['evening_completed'] as int) != 0) ||
              ((sessionRows.first['is_review_only'] as int) != 0));

      await _scheduleWindow(
        morningTime: meta[AppMetaKeys.morningReminder] ?? '09:00',
        eveningTime: meta[AppMetaKeys.eveningReminder] ?? '20:00',
        placementDone: meta[AppMetaKeys.placementCompleted] == 'true',
        skipTodayMorning: skipMorning,
        skipTodayEvening: skipEvening,
      );

      await userDb.insert(
        'app_meta',
        {'key': AppMetaKeys.lastNotifRefillDate, 'value': todayKey},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      lexoraLog('NotificationService.refillSevenDayScheduleInBackground error: $e');
    }
  }

  /// Cancels today's morning reminder (`id = 100`) upon completing the morning session.
  static Future<void> cancelTodayMorning() async {
    try {
      await initialize();
      if (!_initialized) return;
      await _plugin.cancel(AppConstants.morningNotifIdBase);
    } catch (e) {
      lexoraLog('NotificationService.cancelTodayMorning error: $e');
    }
  }

  /// Cancels today's evening reminder (`id = 200`) upon completing the evening Cloze session.
  static Future<void> cancelTodayEvening() async {
    try {
      await initialize();
      if (!_initialized) return;
      await _plugin.cancel(AppConstants.eveningNotifIdBase);
    } catch (e) {
      lexoraLog('NotificationService.cancelTodayEvening error: $e');
    }
  }

  static Future<void> _scheduleWindow({
    required String morningTime,
    required String eveningTime,
    required bool placementDone,
    required bool skipTodayMorning,
    required bool skipTodayEvening,
  }) async {
    // Cancel all 14 slots first so stale schedules never linger.
    for (var day = 0; day < AppConstants.rollingNotifDays; day++) {
      try {
        await _plugin.cancel(AppConstants.morningNotifIdBase + day);
        await _plugin.cancel(AppConstants.eveningNotifIdBase + day);
      } catch (e) {
        lexoraLog('Notification cancel slot $day error: $e');
      }
    }

    if (!placementDone) return;

    final now = tz.TZDateTime.now(tz.local);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: 'ic_stat_notify',
      ),
    );

    final parsedMorning = _parseHhMm(morningTime);
    final parsedEvening = _parseHhMm(eveningTime);

    for (var offset = 0; offset < AppConstants.rollingNotifDays; offset++) {
      final targetDay = now.add(Duration(days: offset));

      if (parsedMorning != null && !(offset == 0 && skipTodayMorning)) {
        final scheduled = tz.TZDateTime(
          tz.local,
          targetDay.year,
          targetDay.month,
          targetDay.day,
          parsedMorning.hour,
          parsedMorning.minute,
        );
        if (scheduled.isAfter(now)) {
          try {
            await _plugin.zonedSchedule(
              AppConstants.morningNotifIdBase + offset,
              'Lexora • Sabah Oturumu',
              'Günün kelimelerini ve tekrarlarını gözden geçirme zamanı.',
              scheduled,
              details,
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
            );
          } catch (e) {
            lexoraLog('Notification schedule morning+$offset error: $e');
          }
        }
      }

      if (parsedEvening != null && !(offset == 0 && skipTodayEvening)) {
        final scheduled = tz.TZDateTime(
          tz.local,
          targetDay.year,
          targetDay.month,
          targetDay.day,
          parsedEvening.hour,
          parsedEvening.minute,
        );
        if (scheduled.isAfter(now)) {
          try {
            await _plugin.zonedSchedule(
              AppConstants.eveningNotifIdBase + offset,
              'Lexora • Akşam Cloze Testi',
              'Bugünkü yeni kelimelerini cümle içinde pekiştir.',
              scheduled,
              details,
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
            );
          } catch (e) {
            lexoraLog('Notification schedule evening+$offset error: $e');
          }
        }
      }
    }
  }

  static ({int hour, int minute})? _parseHhMm(String raw) {
    if (raw == 'off') return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return (hour: h, minute: m);
  }
}
