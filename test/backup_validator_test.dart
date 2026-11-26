import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexora/core/constants.dart';
import 'package:lexora/services/backup_validator.dart';

String _validBackupJson({
  List<Map<String, Object?>>? progress,
  Map<String, Object?>? meta,
  Object? schemaVersion = 2,
}) {
  return jsonEncode({
    'schema_version': schemaVersion,
    'app_meta': meta ??
        {
          AppMetaKeys.placementCompleted: 'true',
          AppMetaKeys.targetStartLevel: 'B2',
          AppMetaKeys.defaultAccent: 'uk',
          AppMetaKeys.currentStreak: '3',
          AppMetaKeys.longestStreak: '5',
          AppMetaKeys.lastCompletedDate: '2026-05-10',
        },
    'user_progress': progress ??
        [
          {
            'word_key': 'schedule',
            'score': 75,
            'next_review_date': '2026-05-24',
            'review_count': 2,
            'lapse_count': 0,
            'user_sentence': 'The train left on schedule.',
            'last_reviewed_at': '2026-05-10T09:00:00',
            'created_at': '2026-05-01T09:00:00',
          },
        ],
  });
}

void main() {
  group('BackupValidator security & integrity checks', () {
    test('accepts valid schema v2 payload with leading UTF-8 BOM and strips disallowed meta', () {
      final raw = '\uFEFF${_validBackupJson(meta: {
        AppMetaKeys.placementCompleted: 'true',
        AppMetaKeys.targetStartLevel: 'B2',
        AppMetaKeys.dictSignature: 'attacker_override_attempt',
        AppMetaKeys.dictReady: '0',
      })}';

      final parsed = BackupValidator.parseAndValidate(raw);
      expect(parsed.progressRows.length, 1);
      expect(parsed.progressRows.first.wordKey, 'schedule');
      expect(parsed.meta[AppMetaKeys.targetStartLevel], 'B2');
      // Unauthorized internal keys must never pass whitelist
      expect(parsed.meta.containsKey(AppMetaKeys.dictSignature), isFalse);
      expect(parsed.meta.containsKey(AppMetaKeys.dictReady), isFalse);
    });

    test('rejects JSON depth bombs exceeding max depth 16 before jsonDecode', () {
      final bomb = '${'[' * 17}1${']' * 17}';
      expect(
        () => BackupValidator.assertMaxJsonDepth(bomb, maxDepth: 16),
        throwsA(isA<BackupValidationException>()),
      );
      expect(
        () => BackupValidator.parseAndValidate(bomb),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('ignores brackets inside JSON string literals when counting depth', () {
      final validWithBracketsInString = _validBackupJson(
        progress: [
          {
            'word_key': 'schedule',
            'score': 50,
            'next_review_date': '2026-05-24',
            'review_count': 1,
            'lapse_count': 0,
            'user_sentence': 'String with [[[[[[[[[[[[[[[[[[[[ brackets',
            'last_reviewed_at': null,
            'created_at': '2026-05-01T09:00:00',
          },
        ],
      );
      final parsed = BackupValidator.parseAndValidate(validWithBracketsInString);
      expect(parsed.progressRows.length, 1);
    });

    test('rejects invalid calendar dates on round-trip check', () {
      final badDates = ['2026-02-30', '2025-02-29', '2026-13-01', '2026-04-31'];
      for (final d in badDates) {
        final raw = _validBackupJson(
          progress: [
            {
              'word_key': 'schedule',
              'score': 50,
              'next_review_date': d,
              'review_count': 1,
              'lapse_count': 0,
              'user_sentence': '',
              'last_reviewed_at': null,
              'created_at': '2026-05-01T09:00:00',
            },
          ],
        );
        expect(
          () => BackupValidator.parseAndValidate(raw),
          throwsA(isA<BackupValidationException>()),
          reason: 'Should reject invalid calendar date: $d',
        );
      }
    });

    test('rejects duplicate word_key after normalizeQuery (Turkish İ / casing / spaces)', () {
      final dupRaw = _validBackupJson(
        progress: [
          {
            'word_key': 'İcon',
            'score': 40,
            'next_review_date': '2026-05-24',
            'review_count': 1,
            'lapse_count': 0,
            'user_sentence': '',
            'last_reviewed_at': null,
            'created_at': '2026-05-01T09:00:00',
          },
          {
            'word_key': '  icon  ',
            'score': 60,
            'next_review_date': '2026-05-24',
            'review_count': 2,
            'lapse_count': 0,
            'user_sentence': '',
            'last_reviewed_at': null,
            'created_at': '2026-05-01T09:00:00',
          },
        ],
      );
      expect(
        () => BackupValidator.parseAndValidate(dupRaw),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('rejects type confusion, out-of-range counters, longest < current streak, and >256 meta', () {
      // Wrong schema_version
      expect(
        () => BackupValidator.parseAndValidate(_validBackupJson(schemaVersion: 1)),
        throwsA(isA<BackupValidationException>()),
      );

      // longest_streak < current_streak
      expect(
        () => BackupValidator.parseAndValidate(
          _validBackupJson(
            meta: {
              AppMetaKeys.currentStreak: '10',
              AppMetaKeys.longestStreak: '5',
            },
          ),
        ),
        throwsA(isA<BackupValidationException>()),
      );

      // score out of range
      expect(
        () => BackupValidator.parseAndValidate(
          _validBackupJson(
            progress: [
              {
                'word_key': 'vitamin',
                'score': 101,
                'next_review_date': '2026-05-24',
                'review_count': 0,
                'lapse_count': 0,
                'user_sentence': '',
                'last_reviewed_at': null,
                'created_at': '2026-05-01T09:00:00',
              },
            ],
          ),
        ),
        throwsA(isA<BackupValidationException>()),
      );

      // app_meta value > 256 characters
      expect(
        () => BackupValidator.parseAndValidate(
          _validBackupJson(
            meta: {
              AppMetaKeys.recentSearches: '["${'a' * 260}"]',
            },
          ),
        ),
        throwsA(isA<BackupValidationException>()),
      );
    });
  });
}
