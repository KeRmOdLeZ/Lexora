import 'package:flutter/foundation.dart';

/// Application-wide constants locked to the Lexora v2.0.0 specification.
abstract final class AppConstants {
  static const String appName = 'Lexora';
  static const String appVersion = '2.0.0';
  static const String packageName = 'com.lexora.app';
  static const String deepLinkScheme = 'lexora';
  static const String backupFilePrefix = 'lexora_backup_';
  static const String httpUserAgent =
      'LexoraAndroid/2.0.0 (Offline Monolingual Dictionary; Android)';

  static const String userDbName = 'user_data.db';
  static const String dictDbName = 'vocab_dict.db';
  static const String dictSchemaVersion = '2';

  static const String dictExtractorMethodChannel =
      'com.lexora.app/dict_extractor';
  static const String dictExtractorProgressChannel =
      'com.lexora.app/dict_extractor_progress';

  static const String wikimediaCommonsBase =
      'https://upload.wikimedia.org/wikipedia/commons/';

  static const int sqlInChunkSize = 500;
  static const int maxNavDepth = 15;
  static const int maxRecentSearches = 20;

  static const int maxAudioCacheBytes = 50 * 1024 * 1024; // 50 MB
  static const int minAudioFileBytes = 512;
  static const int maxAudioFileBytes = 2 * 1024 * 1024; // 2 MB
  static const int maxUnplayableAudioKeys = 500;
  static const int maxRedirectHops = 2;

  static const int maxBackupBytes = 10 * 1024 * 1024; // 10 MB
  static const int maxJsonDepth = 16;
  static const int maxUserSentenceLength = 500;
  static const int maxUserSentenceLines = 3;
  static const int maxImportMetaValueLength = 256;
  static const int maxCounterValue = 100000;

  static const int dailyNewWordsTarget = 7;
  static const int maxOverdueReviewsPerDay = 25;
  static const int reviewOnlyBacklogThreshold = 20;
  static const int initialNewWordScore = 20;
  static const int placementCorrectScore = 75;
  static const int placementCorrectIntervalDays = 14;

  static const int morningNotifIdBase = 100;
  static const int eveningNotifIdBase = 200;
  static const int rollingNotifDays = 7;
  static const int notifRefillThresholdDays = 3;
  static const int widgetDozeToleranceMs = 15 * 60 * 1000; // 15 minutes
  static const int widgetManualRefreshCooldownMs = 1000; // 1 second

  static const String workTaskWidgetRotate = 'widget_rotate_task';
  static const String workTaskAudioCache = 'audio_cache_task';

  static const List<String> allCefrLevels = ['A1', 'A2', 'B1', 'B2', 'C1', 'C2'];
  static const List<String> studyCefrLevels = ['B1', 'B2', 'C1', 'C2'];

  static const List<String> ipaFontFallback = [
    'Noto Sans',
    'Roboto',
    'sans-serif',
  ];
}

/// Keys stored in `user_data.db` -> `app_meta`.
abstract final class AppMetaKeys {
  static const String dictSignature = 'dict_signature';
  static const String dictSchemaVersion = 'dict_schema_version';
  static const String dictReady = 'dict_ready';
  static const String placementCompleted = 'placement_completed';
  static const String targetStartLevel = 'target_start_level';
  static const String defaultAccent = 'default_accent';
  static const String widgetIntervalHours = 'widget_interval_hours';
  static const String widgetLastUpdatedMs = 'widget_last_updated_ms';
  static const String currentWidgetWordKey = 'current_widget_word_key';
  static const String currentStreak = 'current_streak';
  static const String longestStreak = 'longest_streak';
  static const String lastCompletedDate = 'last_completed_date';
  static const String morningReminder = 'morning_reminder';
  static const String eveningReminder = 'evening_reminder';
  static const String lastNotifRefillDate = 'last_notif_refill_date';
  static const String autoPlayAudio = 'auto_play_audio';
  static const String themeMode = 'theme_mode';
  static const String recentSearches = 'recent_searches';

  static const Map<String, String> defaults = {
    dictSchemaVersion: AppConstants.dictSchemaVersion,
    dictReady: '0',
    placementCompleted: 'false',
    targetStartLevel: 'B1',
    defaultAccent: 'us',
    widgetIntervalHours: '6',
    widgetLastUpdatedMs: '0',
    currentWidgetWordKey: '',
    currentStreak: '0',
    longestStreak: '0',
    lastCompletedDate: '',
    morningReminder: '09:00',
    eveningReminder: '20:00',
    lastNotifRefillDate: '',
    autoPlayAudio: 'true',
    themeMode: 'dark',
    recentSearches: '[]',
  };
}

/// Keys stored in HomeWidget SharedPreferences (strictly 5 strings for display).
abstract final class WidgetDataKeys {
  static const String wordKey = 'widget_word_key';
  static const String wordDisplay = 'widget_word_display';
  static const String level = 'widget_level';
  static const String ipa = 'widget_ipa';
  static const String meaning = 'widget_meaning';
  static const String widgetActive = 'widget_active';
}

/// Release-silent debug logger.
void lexoraLog(String message) {
  if (kDebugMode) {
    debugPrint('[Lexora] $message');
  }
}
