import 'package:flutter_test/flutter_test.dart';
import 'package:lexora/core/date_utils.dart';
import 'package:lexora/services/srs_engine.dart';

void main() {
  group('LexoraDateUtils DST-safe calendar arithmetic', () {
    test('calculates exact day differences across DST boundaries and leap years', () {
      // US spring-forward weekend (2026-03-08)
      expect(LexoraDateUtils.daysBetweenDateKeys('2026-03-07', '2026-03-09'), 2);
      // US fall-back weekend (2026-11-01)
      expect(LexoraDateUtils.daysBetweenDateKeys('2026-10-31', '2026-11-02'), 2);
      // Leap year February 2024
      expect(LexoraDateUtils.daysBetweenDateKeys('2024-02-28', '2024-03-01'), 2);
      expect(LexoraDateUtils.addDaysToDateKey('2024-02-28', 1), '2024-02-29');
      expect(LexoraDateUtils.addDaysToDateKey('2025-02-28', 1), '2025-03-01');
    });

    test('validates calendar round-trip strictly', () {
      expect(LexoraDateUtils.parseDateKeyStrict('2024-02-29'), isNotNull);
      expect(LexoraDateUtils.parseDateKeyStrict('2025-02-29'), isNull);
      expect(LexoraDateUtils.parseDateKeyStrict('2026-02-30'), isNull);
      expect(LexoraDateUtils.parseDateKeyStrict('2026-13-01'), isNull);
      expect(LexoraDateUtils.parseDateKeyStrict('2026-04-31'), isNull);
    });
  });

  group('SrsEngine score table, lapse cap, backlog guard, placement, streak', () {
    test('maps score buckets to exact SRS intervals', () {
      expect(SrsEngine.intervalDaysForScore(0), 1);
      expect(SrsEngine.intervalDaysForScore(29), 1);
      expect(SrsEngine.intervalDaysForScore(30), 2);
      expect(SrsEngine.intervalDaysForScore(49), 2);
      expect(SrsEngine.intervalDaysForScore(50), 4);
      expect(SrsEngine.intervalDaysForScore(69), 4);
      expect(SrsEngine.intervalDaysForScore(70), 7);
      expect(SrsEngine.intervalDaysForScore(84), 7);
      expect(SrsEngine.intervalDaysForScore(85), 14);
      expect(SrsEngine.intervalDaysForScore(94), 14);
      expect(SrsEngine.intervalDaysForScore(95), 30);
      expect(SrsEngine.intervalDaysForScore(100), 30);
    });

    test('enforces lapse cap min(score - 15, 65) and +1 day on Morning Step 1 failure', () {
      final res90 = SrsEngine.computeMorningOutcome(
        currentScore: 90,
        isNewWord: false,
        knewMeaning: false,
        knewPronunciation: true, // +5 must NOT bypass lapse cap 65
        reviewCount: 5,
        lapseCount: 0,
        sessionDate: '2026-05-10',
      );
      expect(res90.newScore, 65);
      expect(res90.newLapseCount, 1);
      expect(res90.nextReviewDate, '2026-05-11');
      expect(res90.hadError, isTrue);

      final res75 = SrsEngine.computeMorningOutcome(
        currentScore: 75,
        isNewWord: false,
        knewMeaning: false,
        knewPronunciation: true,
        reviewCount: 3,
        lapseCount: 1,
        sessionDate: '2026-05-10',
      );
      expect(res75.newScore, 60); // min(75 - 15, 65) == 60
      expect(res75.newLapseCount, 2);
      expect(res75.nextReviewDate, '2026-05-11');
    });

    test('enforces lapse cap and morning error +1 day rule in Evening Cloze', () {
      final lapse = SrsEngine.computeEveningClozeOutcome(
        currentScore: 88,
        isCorrect: false,
        hadMorningError: false,
        reviewCount: 4,
        lapseCount: 0,
        sessionDate: '2026-05-10',
      );
      expect(lapse.newScore, 65);
      expect(lapse.newLapseCount, 1);
      expect(lapse.nextReviewDate, '2026-05-11');

      final morningErrCorrect = SrsEngine.computeEveningClozeOutcome(
        currentScore: 55,
        isCorrect: true,
        hadMorningError: true,
        reviewCount: 1,
        lapseCount: 0,
        sessionDate: '2026-05-10',
      );
      expect(morningErrCorrect.newScore, 70);
      expect(morningErrCorrect.nextReviewDate, '2026-05-11'); // forced +1d due to morning error
    });

    test('activates review-only backlog guard at >= 20 overdue words', () {
      expect(SrsEngine.isReviewOnlyDay(0), isFalse);
      expect(SrsEngine.isReviewOnlyDay(19), isFalse);
      expect(SrsEngine.isReviewOnlyDay(20), isTrue);
      expect(SrsEngine.isReviewOnlyDay(25), isTrue);
    });

    test('evaluates Placement Test consecutive mastery rule accurately', () {
      expect(
        SrsEngine.computePlacementStartLevel(b1Correct: 2, b2Correct: 4, c1Correct: 4),
        'B1',
      );
      expect(
        SrsEngine.computePlacementStartLevel(b1Correct: 3, b2Correct: 2, c1Correct: 4),
        'B2',
      );
      expect(
        SrsEngine.computePlacementStartLevel(b1Correct: 3, b2Correct: 3, c1Correct: 2),
        'C1',
      );
      expect(
        SrsEngine.computePlacementStartLevel(b1Correct: 4, b2Correct: 3, c1Correct: 3),
        'C2',
      );
    });

    test('updates streak idempotently and resets when daysDiff > 1', () {
      final sameDay = SrsEngine.computeStreakUpdate(
        currentStreak: 4,
        longestStreak: 7,
        lastCompletedDate: '2026-05-10',
        sessionDate: '2026-05-10',
      );
      expect(sameDay.didIncrement, isFalse);
      expect(sameDay.currentStreak, 4);

      final consecutive = SrsEngine.computeStreakUpdate(
        currentStreak: 4,
        longestStreak: 4,
        lastCompletedDate: '2026-05-10',
        sessionDate: '2026-05-11',
      );
      expect(consecutive.didIncrement, isTrue);
      expect(consecutive.currentStreak, 5);
      expect(consecutive.longestStreak, 5);

      final broken = SrsEngine.computeStreakUpdate(
        currentStreak: 5,
        longestStreak: 10,
        lastCompletedDate: '2026-05-11',
        sessionDate: '2026-05-14',
      );
      expect(broken.didIncrement, isTrue);
      expect(broken.currentStreak, 1);
      expect(broken.longestStreak, 10);
    });
  });
}
