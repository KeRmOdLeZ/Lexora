import 'dart:math';

import '../core/constants.dart';
import '../core/date_utils.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';

/// Outcome of a single word card during the Morning Session.
class MorningCardOutcome {
  const MorningCardOutcome({
    required this.newScore,
    required this.nextReviewDate,
    required this.newReviewCount,
    required this.newLapseCount,
    required this.hadError,
  });

  final int newScore;
  final String nextReviewDate;
  final int newReviewCount;
  final int newLapseCount;
  final bool hadError;
}

/// Outcome of a single Cloze question during the Evening Session.
class EveningClozeOutcome {
  const EveningClozeOutcome({
    required this.newScore,
    required this.nextReviewDate,
    required this.newReviewCount,
    required this.newLapseCount,
  });

  final int newScore;
  final String nextReviewDate;
  final int newReviewCount;
  final int newLapseCount;
}

/// Result of streak recalculation.
class StreakUpdate {
  const StreakUpdate({
    required this.currentStreak,
    required this.longestStreak,
    required this.lastCompletedDate,
    required this.didIncrement,
  });

  final int currentStreak;
  final int longestStreak;
  final String lastCompletedDate;
  final bool didIncrement;
}

/// Prepared Cloze question with masked prompt and properly cased choices.
class ClozeQuestion {
  const ClozeQuestion({
    required this.target,
    required this.originalSentence,
    required this.maskedPrompt,
    required this.isBlankAtStart,
    required this.options,
    required this.correctIndex,
    required this.usedDefinitionFallback,
  });

  final WordEntry target;
  final String originalSentence;
  final String maskedPrompt;
  final bool isBlankAtStart;
  final List<String> options;
  final int correctIndex;
  final bool usedDefinitionFallback;
}

/// Pure, deterministic SRS, Placement, Streak, and Backlog algorithms.
abstract final class SrsEngine {
  /// Score -> Review interval days table:
  /// 0-29: +1d, 30-49: +2d, 50-69: +4d, 70-84: +7d, 85-94: +14d, 95-100: +30d.
  static int intervalDaysForScore(int score) {
    final s = score.clamp(0, 100);
    if (s <= 29) return 1;
    if (s <= 49) return 2;
    if (s <= 69) return 4;
    if (s <= 84) return 7;
    if (s <= 94) return 14;
    return 30;
  }

  /// Backlog guard: when overdue count >= 20, the day becomes review-only.
  static bool isReviewOnlyDay(int overdueCount) {
    return overdueCount >= AppConstants.reviewOnlyBacklogThreshold;
  }

  /// Consecutive Mastery Rule for the 16-question Placement Test (4 per level):
  /// Starts B1 -> B1>=3/4 => B2 -> B1&B2>=3/4 => C1 -> B1&B2&C1>=3/4 => C2.
  static String computePlacementStartLevel({
    required int b1Correct,
    required int b2Correct,
    required int c1Correct,
  }) {
    if (b1Correct < 3) return 'B1';
    if (b2Correct < 3) return 'B2';
    if (c1Correct < 3) return 'C1';
    return 'C2';
  }

  /// Computes Morning Session score, lapse cap, and next review date.
  static MorningCardOutcome computeMorningOutcome({
    required int currentScore,
    required bool isNewWord,
    required bool knewMeaning,
    required bool knewPronunciation,
    required int reviewCount,
    required int lapseCount,
    required String sessionDate,
  }) {
    final baseScore = isNewWord ? AppConstants.initialNewWordScore : currentScore;
    final step1Delta = knewMeaning ? 15 : -15;
    final step2Delta = knewPronunciation ? 5 : -10;

    var score = (baseScore + step1Delta + step2Delta).clamp(0, 100);
    var nextLapseCount = lapseCount;
    var forcedNextDay = false;

    // Lapse Cap: score >= 70 & Step 1 wrong => cap to min(score - 15, 65) and +1 day.
    if (!isNewWord && currentScore >= 70 && !knewMeaning) {
      final cap = min(currentScore - 15, 65);
      score = min(score, cap).clamp(0, 100);
      nextLapseCount += 1;
      forcedNextDay = true;
    } else if (!isNewWord && !knewMeaning) {
      nextLapseCount += 1;
    }

    final int intervalDays;
    if (isNewWord) {
      // Safe fallback until Evening Cloze settles final interval.
      intervalDays = 1;
    } else if (forcedNextDay || !knewMeaning) {
      intervalDays = 1;
    } else {
      intervalDays = intervalDaysForScore(score);
    }

    return MorningCardOutcome(
      newScore: score,
      nextReviewDate: LexoraDateUtils.addDaysToDateKey(sessionDate, intervalDays),
      newReviewCount: reviewCount + 1,
      newLapseCount: nextLapseCount,
      hadError: !knewMeaning,
    );
  }

  /// Computes Evening Cloze score (+15 / -15), lapse cap, and final SRS date.
  static EveningClozeOutcome computeEveningClozeOutcome({
    required int currentScore,
    required bool isCorrect,
    required bool hadMorningError,
    required int reviewCount,
    required int lapseCount,
    required String sessionDate,
  }) {
    var score = (currentScore + (isCorrect ? 15 : -15)).clamp(0, 100);
    var nextLapseCount = lapseCount;

    if (!isCorrect && currentScore >= 70) {
      final cap = min(currentScore - 15, 65);
      score = min(score, cap).clamp(0, 100);
      nextLapseCount += 1;
    } else if (!isCorrect) {
      nextLapseCount += 1;
    }

    final intervalDays = (!isCorrect || hadMorningError)
        ? 1
        : intervalDaysForScore(score);

    return EveningClozeOutcome(
      newScore: score,
      nextReviewDate: LexoraDateUtils.addDaysToDateKey(sessionDate, intervalDays),
      newReviewCount: reviewCount + 1,
      newLapseCount: nextLapseCount,
    );
  }

  /// Computes idempotent daily streak update using DST-safe date key difference.
  static StreakUpdate computeStreakUpdate({
    required int currentStreak,
    required int longestStreak,
    required String? lastCompletedDate,
    required String sessionDate,
  }) {
    if (lastCompletedDate != null &&
        lastCompletedDate.isNotEmpty &&
        lastCompletedDate == sessionDate) {
      return StreakUpdate(
        currentStreak: currentStreak,
        longestStreak: max(longestStreak, currentStreak),
        lastCompletedDate: lastCompletedDate,
        didIncrement: false,
      );
    }

    var nextCurrent = 1;
    if (lastCompletedDate != null &&
        lastCompletedDate.isNotEmpty &&
        LexoraDateUtils.parseDateKeyStrict(lastCompletedDate) != null) {
      final diff = LexoraDateUtils.daysBetweenDateKeys(
        lastCompletedDate,
        sessionDate,
      );
      if (diff == 1) {
        nextCurrent = currentStreak + 1;
      } else if (diff <= 0) {
        // Guard against clock skew moving backward: preserve existing streak.
        return StreakUpdate(
          currentStreak: currentStreak,
          longestStreak: max(longestStreak, currentStreak),
          lastCompletedDate: lastCompletedDate,
          didIncrement: false,
        );
      } else {
        // diff > 1 -> streak broken, reset to 1.
        nextCurrent = 1;
      }
    }

    final nextLongest = max(longestStreak, nextCurrent);
    return StreakUpdate(
      currentStreak: nextCurrent,
      longestStreak: nextLongest,
      lastCompletedDate: sessionDate,
      didIncrement: true,
    );
  }

  /// Waterfall CEFR priority order for picking 7 new words:
  /// target_start_level -> higher levels -> lower B1+ levels.
  static List<String> waterfallLevelsFor(String targetStartLevel) {
    const levels = AppConstants.studyCefrLevels; // ['B1', 'B2', 'C1', 'C2']
    final idx = levels.indexOf(targetStartLevel);
    if (idx < 0) return levels;
    final ordered = <String>[];
    for (var i = idx; i < levels.length; i++) {
      ordered.add(levels[i]);
    }
    for (var i = idx - 1; i >= 0; i--) {
      ordered.add(levels[i]);
    }
    return ordered;
  }
}

/// Pure Cloze sentence masking, `a(n)` normalization, casing, and 3-tier distractor engine.
abstract final class ClozeEngine {
  static final RegExp _articleAtStartRegex = RegExp(
    r'(^|[.!?]\s+)(a|an)\s+_____',
    caseSensitive: false,
  );
  static final RegExp _articleMidRegex = RegExp(
    r'\b(a|an)\s+_____',
    caseSensitive: false,
  );
  static final RegExp _blankAtStartRegex = RegExp(
    r'^\s*["“‘(]*_____',
  );

  /// Masks all whole-word occurrences of `targetWord` using Unicode Latin lookarounds,
  /// then converts `a/an _____` into `A(n) _____` at sentence start or `a(n) _____` inline.
  static ({String masked, bool isBlankAtStart, bool matchedTarget}) maskSentence(
    String sentence,
    String targetWord,
  ) {
    final escaped = RegExp.escape(targetWord.trim());
    if (escaped.isEmpty) {
      return (masked: sentence, isBlankAtStart: false, matchedTarget: false);
    }

    final wordRegex = RegExp(
      '(?<![\\p{Script=Latin}0-9-])$escaped(?![\\p{Script=Latin}0-9-])',
      unicode: true,
      caseSensitive: false,
    );

    final matched = wordRegex.hasMatch(sentence);
    var masked = sentence.replaceAll(wordRegex, '_____');

    // Neutralize indefinite articles directly before the blank.
    masked = masked.replaceAllMapped(_articleAtStartRegex, (m) {
      final prefix = m.group(1) ?? '';
      return '${prefix}A(n) _____';
    });
    masked = masked.replaceAllMapped(_articleMidRegex, (m) => 'a(n) _____');

    final blankAtStart = _blankAtStartRegex.hasMatch(masked);
    return (
      masked: masked,
      isBlankAtStart: blankAtStart,
      matchedTarget: matched,
    );
  }

  /// Masks target word inside a definition (used in Placement Test and Cloze fallback).
  static String maskDefinition(String definition, String targetWord) {
    return maskSentence(definition, targetWord).masked;
  }

  /// Applies consistent capitalization across all 4 Cloze answer choices:
  /// capitalized if the blank starts the sentence, lowercase otherwise.
  static String formatChoiceCasing(String wordDisplay, {required bool capitalize}) {
    final trimmed = wordDisplay.trim();
    if (trimmed.isEmpty) return trimmed;
    final runes = trimmed.runes.toList(growable: false);
    final first = String.fromCharCode(runes.first);
    final rest = runes.length > 1 ? String.fromCharCodes(runes.sublist(1)) : '';
    return capitalize
        ? '${first.toUpperCase()}$rest'
        : '${first.toLowerCase()}$rest';
  }

  /// 3-tier distractor selection:
  /// Tier 1: same level + same primary_pos + same wordCount
  /// Tier 2: any B1..C2 + same primary_pos + same wordCount
  /// Tier 3: any B1..C2
  /// Filters out target, synonyms, shared 5+ letter stem, and words present in sentence.
  static List<WordEntry> selectDistractors({
    required WordEntry target,
    required String sentence,
    required List<WordEntry> candidatePool,
    int count = 3,
    Random? random,
  }) {
    final rng = random ?? Random();
    final targetKey = target.wordKey;
    final targetSyns = target.synonyms.map(TextNormalizer.normalizeQuery).toSet();
    final sentenceNorm = TextNormalizer.normalizeQuery(sentence);

    bool isValidCandidate(WordEntry c, Set<String> chosenKeys) {
      if (c.wordKey == targetKey || chosenKeys.contains(c.wordKey)) return false;
      if (c.level == null || !AppConstants.studyCefrLevels.contains(c.level)) {
        return false;
      }
      if (targetSyns.contains(c.wordKey)) return false;
      final cSyns = c.synonyms.map(TextNormalizer.normalizeQuery);
      if (cSyns.contains(targetKey)) return false;

      // Reject shared 5+ letter prefix stem (e.g. compare vs comparable / comparison)
      if (_sharesStem(targetKey, c.wordKey)) return false;

      // Reject candidate that already appears in the Cloze sentence
      final cRegex = RegExp(
        '(?<![\\p{Script=Latin}0-9-])${RegExp.escape(c.wordKey)}(?![\\p{Script=Latin}0-9-])',
        unicode: true,
        caseSensitive: false,
      );
      if (cRegex.hasMatch(sentenceNorm)) return false;
      return true;
    }

    final chosen = <WordEntry>[];
    final chosenKeys = <String>{};

    void fillFrom(Iterable<WordEntry> tier) {
      if (chosen.length >= count) return;
      final eligible = tier.where((c) => isValidCandidate(c, chosenKeys)).toList();
      eligible.shuffle(rng);
      for (final item in eligible) {
        if (chosen.length >= count) break;
        chosen.add(item);
        chosenKeys.add(item.wordKey);
      }
    }

    // Tier 1: same level + same POS + same word count
    fillFrom(
      candidatePool.where(
        (c) =>
            c.level == target.level &&
            c.primaryPos == target.primaryPos &&
            c.wordCount == target.wordCount,
      ),
    );

    // Tier 2: any B1..C2 + same POS + same word count
    fillFrom(
      candidatePool.where(
        (c) =>
            c.primaryPos == target.primaryPos &&
            c.wordCount == target.wordCount,
      ),
    );

    // Tier 3: any B1..C2
    fillFrom(candidatePool);

    return chosen;
  }

  /// Builds a complete ClozeQuestion with 4 shuffled, consistently cased options.
  static ClozeQuestion buildQuestion({
    required WordEntry target,
    required List<WordEntry> candidatePool,
    Random? random,
  }) {
    final rng = random ?? Random();

    String sourceText;
    bool usedFallback = false;

    final rawCloze = target.clozeExample?.trim();
    if (rawCloze != null && rawCloze.isNotEmpty) {
      final probe = maskSentence(rawCloze, target.wordDisplay);
      if (probe.matchedTarget) {
        sourceText = rawCloze;
      } else {
        sourceText = target.meaningEn;
        usedFallback = true;
      }
    } else {
      sourceText = target.meaningEn;
      usedFallback = true;
    }

    final maskResult = maskSentence(sourceText, target.wordDisplay);
    final prompt = usedFallback
        ? 'Meaning: ${maskResult.masked}'
        : maskResult.masked;
    final blankAtStart = !usedFallback && maskResult.isBlankAtStart;

    final distractors = selectDistractors(
      target: target,
      sentence: sourceText,
      candidatePool: candidatePool,
      count: 3,
      random: rng,
    );

    final rawChoices = <WordEntry>[target, ...distractors];
    rawChoices.shuffle(rng);

    final correctIdx = rawChoices.indexWhere((e) => e.wordKey == target.wordKey);
    final formattedOptions = rawChoices
        .map((e) => formatChoiceCasing(e.wordDisplay, capitalize: blankAtStart))
        .toList(growable: false);

    return ClozeQuestion(
      target: target,
      originalSentence: sourceText,
      maskedPrompt: prompt,
      isBlankAtStart: blankAtStart,
      options: formattedOptions,
      correctIndex: correctIdx < 0 ? 0 : correctIdx,
      usedDefinitionFallback: usedFallback,
    );
  }

  static bool _sharesStem(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[^a-z]'), '');
    final cleanB = b.replaceAll(RegExp(r'[^a-z]'), '');
    if (cleanA.length < 5 || cleanB.length < 5) return false;
    return cleanA.substring(0, 5) == cleanB.substring(0, 5);
  }
}
