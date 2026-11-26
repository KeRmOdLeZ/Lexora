import 'dart:convert';

import '../core/constants.dart';
import '../core/date_utils.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';

class BackupValidationException implements Exception {
  const BackupValidationException(this.message);

  final String message;

  @override
  String toString() => 'BackupValidationException: $message';
}

class ValidatedBackupData {
  const ValidatedBackupData({
    required this.progressRows,
    required this.meta,
  });

  final List<UserProgress> progressRows;
  final Map<String, String> meta;
}

/// Hardened JSON backup parser & validator protecting against depth bombs,
/// type confusion, invalid calendar dates, BiDi injection, disallowed metadata,
/// and normalized duplicate keys.
abstract final class BackupValidator {
  static const Set<String> allowedImportMetaKeys = {
    AppMetaKeys.placementCompleted,
    AppMetaKeys.targetStartLevel,
    AppMetaKeys.defaultAccent,
    AppMetaKeys.widgetIntervalHours,
    AppMetaKeys.currentStreak,
    AppMetaKeys.longestStreak,
    AppMetaKeys.lastCompletedDate,
    AppMetaKeys.morningReminder,
    AppMetaKeys.eveningReminder,
    AppMetaKeys.autoPlayAudio,
    AppMetaKeys.themeMode,
    AppMetaKeys.recentSearches,
  };

  static final RegExp _hhMmRegex = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

  /// Strips leading UTF-8 BOM (`\uFEFF`) if present.
  static String stripUtf8Bom(String raw) {
    if (raw.startsWith('\uFEFF')) {
      return raw.substring(1);
    }
    return raw;
  }

  /// Single-pass JSON nesting depth scanner run BEFORE `jsonDecode`.
  /// Correctly ignores `{`, `}`, `[`, `]` inside string literals and handles escapes.
  static void assertMaxJsonDepth(
    String jsonText, {
    int maxDepth = AppConstants.maxJsonDepth,
  }) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = 0; i < jsonText.length; i++) {
      final code = jsonText.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == 0x5C) {
          // '\'
          escaped = true;
        } else if (code == 0x22) {
          // '"'
          inString = false;
        }
        continue;
      }

      if (code == 0x22) {
        inString = true;
      } else if (code == 0x7B || code == 0x5B) {
        // '{' or '['
        depth++;
        if (depth > maxDepth) {
          throw BackupValidationException(
            'JSON derinliği izin verilen sınırı ($maxDepth) aşıyor.',
          );
        }
      } else if (code == 0x7D || code == 0x5D) {
        // '}' or ']'
        depth--;
        if (depth < 0) {
          throw const BackupValidationException('Geçersiz JSON yapısı.');
        }
      }
    }
  }

  /// Parses and validates a raw JSON backup payload completely before touching SQLite.
  static ValidatedBackupData parseAndValidate(String rawContent) {
    final cleaned = stripUtf8Bom(rawContent);
    if (cleaned.trim().isEmpty) {
      throw const BackupValidationException('Yedek dosyası boş.');
    }

    assertMaxJsonDepth(cleaned, maxDepth: AppConstants.maxJsonDepth);

    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on Object {
      throw const BackupValidationException('Yedek dosyası geçerli bir JSON değil.');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const BackupValidationException('Yedek kökü JSON nesnesi olmalıdır.');
    }

    // Strict schema_version == 2
    final schemaVersion = decoded['schema_version'];
    if (schemaVersion is! int || schemaVersion != 2) {
      throw const BackupValidationException(
        'Desteklenmeyen yedek şema sürümü (schema_version == 2 bekleniyor).',
      );
    }

    // Validate meta section
    final validatedMeta = <String, String>{};
    final rawMeta = decoded['app_meta'];
    if (rawMeta != null) {
      if (rawMeta is! Map<String, dynamic>) {
        throw const BackupValidationException('app_meta alanı nesne olmalıdır.');
      }
      for (final entry in rawMeta.entries) {
        final key = entry.key;
        if (!allowedImportMetaKeys.contains(key)) {
          // Reject or ignore unknown keys? Hardened whitelist: strictly reject disallowed keys
          // only if malformed, or skip unknown metadata? Wait: spec says
          // "yalnızca sabit _allowedImportMetaKeys izin listesi (her değer <= 256 karakter)"
          // Ignoring unknown keys could hide tampering; wait — checking strictly or filtering?
          // Let's check: only import keys in allowedImportMetaKeys, and validate each imported value!
          continue;
        }
        final val = entry.value;
        if (val is! String) {
          throw BackupValidationException('app_meta.$key metin olmalıdır.');
        }
        if (val.length > AppConstants.maxImportMetaValueLength) {
          throw BackupValidationException(
            'app_meta.$key değeri 256 karakter sınırını aşıyor.',
          );
        }
        validatedMeta[key] = _validateMetaValue(key, val);
      }
    }

    // Cross-validate streak constraints (longest >= current, 0..100000)
    final curStreakStr = validatedMeta[AppMetaKeys.currentStreak];
    final longStreakStr = validatedMeta[AppMetaKeys.longestStreak];
    if (curStreakStr != null || longStreakStr != null) {
      final cur = int.tryParse(curStreakStr ?? '0');
      final longest = int.tryParse(longStreakStr ?? '0');
      if (cur == null ||
          longest == null ||
          cur < 0 ||
          cur > AppConstants.maxCounterValue ||
          longest < 0 ||
          longest > AppConstants.maxCounterValue ||
          longest < cur) {
        throw const BackupValidationException(
          'Geçersiz seri (streak) değerleri (longest >= current ve 0..100000 olmalıdır).',
        );
      }
    }

    // Validate user_progress array
    final rawProgress = decoded['user_progress'];
    if (rawProgress is! List) {
      throw const BackupValidationException('user_progress alanı liste olmalıdır.');
    }

    final seenNormalizedKeys = <String>{};
    final progressRows = <UserProgress>[];

    for (var i = 0; i < rawProgress.length; i++) {
      final item = rawProgress[i];
      if (item is! Map<String, dynamic>) {
        throw BackupValidationException('user_progress[$i] nesne olmalıdır.');
      }

      final rawKey = item['word_key'];
      if (rawKey is! String) {
        throw BackupValidationException('user_progress[$i].word_key metin olmalıdır.');
      }
      final normalizedKey = TextNormalizer.normalizeQuery(rawKey);
      if (normalizedKey.isEmpty || normalizedKey.length > 64) {
        throw BackupValidationException('user_progress[$i].word_key geçersiz.');
      }
      if (!seenNormalizedKeys.add(normalizedKey)) {
        throw BackupValidationException(
          'Normalize edildikten sonra yinelenen kelime anahtarı: "$normalizedKey".',
        );
      }

      final score = item['score'];
      if (score is! int || score < 0 || score > 100) {
        throw BackupValidationException('user_progress[$i].score 0..100 tam sayı olmalıdır.');
      }

      final nextReviewDate = item['next_review_date'];
      if (nextReviewDate is! String ||
          LexoraDateUtils.parseDateKeyStrict(nextReviewDate) == null) {
        throw BackupValidationException(
          'user_progress[$i].next_review_date geçerli YYYY-MM-DD takvim tarihi olmalıdır.',
        );
      }

      final reviewCount = item['review_count'];
      if (reviewCount is! int ||
          reviewCount < 0 ||
          reviewCount > AppConstants.maxCounterValue) {
        throw BackupValidationException(
          'user_progress[$i].review_count 0..100000 tam sayı olmalıdır.',
        );
      }

      final lapseCount = item['lapse_count'];
      if (lapseCount is! int ||
          lapseCount < 0 ||
          lapseCount > AppConstants.maxCounterValue) {
        throw BackupValidationException(
          'user_progress[$i].lapse_count 0..100000 tam sayı olmalıdır.',
        );
      }

      final rawSentence = item['user_sentence'] ?? '';
      if (rawSentence is! String) {
        throw BackupValidationException(
          'user_progress[$i].user_sentence metin olmalıdır.',
        );
      }
      final cleanSentence = TextNormalizer.sanitizeUserSentence(
        rawSentence,
        maxLength: AppConstants.maxUserSentenceLength,
        maxLines: AppConstants.maxUserSentenceLines,
      );

      final lastReviewedAt = item['last_reviewed_at'];
      if (lastReviewedAt != null && lastReviewedAt is! String) {
        throw BackupValidationException(
          'user_progress[$i].last_reviewed_at metin veya null olmalıdır.',
        );
      }
      if (lastReviewedAt is String && lastReviewedAt.length > 64) {
        throw BackupValidationException(
          'user_progress[$i].last_reviewed_at çok uzun.',
        );
      }

      final createdAt = item['created_at'];
      if (createdAt is! String || createdAt.isEmpty || createdAt.length > 64) {
        throw BackupValidationException(
          'user_progress[$i].created_at geçersiz.',
        );
      }

      progressRows.add(
        UserProgress(
          wordKey: normalizedKey,
          score: score,
          nextReviewDate: nextReviewDate,
          reviewCount: reviewCount,
          lapseCount: lapseCount,
          userSentence: cleanSentence,
          lastReviewedAt: lastReviewedAt as String?,
          createdAt: TextNormalizer.stripControlAndBidi(createdAt),
        ),
      );
    }

    return ValidatedBackupData(
      progressRows: progressRows,
      meta: validatedMeta,
    );
  }

  static String _validateMetaValue(String key, String rawVal) {
    final val = TextNormalizer.stripControlAndBidi(rawVal);
    switch (key) {
      case AppMetaKeys.placementCompleted:
      case AppMetaKeys.autoPlayAudio:
        if (val != 'true' && val != 'false') {
          throw BackupValidationException('$key yalnızca true/false olabilir.');
        }
        return val;
      case AppMetaKeys.targetStartLevel:
        if (!AppConstants.studyCefrLevels.contains(val)) {
          throw BackupValidationException('$key yalnızca B1..C2 olabilir.');
        }
        return val;
      case AppMetaKeys.defaultAccent:
        if (val != 'us' && val != 'uk') {
          throw BackupValidationException('$key yalnızca us/uk olabilir.');
        }
        return val;
      case AppMetaKeys.widgetIntervalHours:
        if (val != '6' && val != '12' && val != '24') {
          throw BackupValidationException('$key yalnızca 6/12/24 olabilir.');
        }
        return val;
      case AppMetaKeys.themeMode:
        if (val != 'dark' && val != 'system' && val != 'light') {
          throw BackupValidationException('$key yalnızca dark/system/light olabilir.');
        }
        return val;
      case AppMetaKeys.currentStreak:
      case AppMetaKeys.longestStreak:
        final n = int.tryParse(val);
        if (n == null || n < 0 || n > AppConstants.maxCounterValue) {
          throw BackupValidationException('$key 0..100000 tam sayı olmalıdır.');
        }
        return n.toString();
      case AppMetaKeys.lastCompletedDate:
        if (val.isNotEmpty && LexoraDateUtils.parseDateKeyStrict(val) == null) {
          throw BackupValidationException('$key geçerli YYYY-MM-DD olmalıdır.');
        }
        return val;
      case AppMetaKeys.morningReminder:
      case AppMetaKeys.eveningReminder:
        if (val != 'off' && !_hhMmRegex.hasMatch(val)) {
          throw BackupValidationException('$key HH:MM veya off olmalıdır.');
        }
        return val;
      case AppMetaKeys.recentSearches:
        try {
          final parsed = jsonDecode(val);
          if (parsed is! List) {
            throw const BackupValidationException('recent_searches liste olmalıdır.');
          }
          final clean = <String>[];
          for (final item in parsed) {
            if (item is! String) {
              throw const BackupValidationException('recent_searches öğesi metin olmalıdır.');
            }
            final norm = TextNormalizer.normalizeQuery(item);
            if (norm.isNotEmpty && !clean.contains(norm) && clean.length < AppConstants.maxRecentSearches) {
              clean.add(norm);
            }
          }
          return jsonEncode(clean);
        } on BackupValidationException {
          rethrow;
        } on Object {
          throw const BackupValidationException('recent_searches JSON biçimi geçersiz.');
        }
      default:
        return val;
    }
  }
}
