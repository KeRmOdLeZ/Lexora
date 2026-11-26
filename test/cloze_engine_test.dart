import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexora/models/word_entry.dart';
import 'package:lexora/services/srs_engine.dart';

WordEntry _word({
  required String key,
  String? display,
  String? level = 'B2',
  String pos = 'adjective',
  String meaning = 'A clear test meaning.',
  String? cloze,
  List<String> synonyms = const [],
}) {
  return WordEntry(
    wordKey: key,
    wordDisplay: display ?? key,
    level: level,
    primaryPos: pos,
    meaningEn: meaning,
    senses: const [],
    examples: const [],
    clozeExample: cloze,
    synonyms: synonyms,
    ipaUs: null,
    ipaUk: null,
    audioUs: null,
    audioUk: null,
  );
}

void main() {
  group('ClozeEngine masking, a(n) neutralization, and casing', () {
    test('masks whole Unicode Latin words and avoids partial substring matches', () {
      final res = ClozeEngine.maskSentence(
        'Her naïve assumption seemed Naïve even to comparing observers.',
        'naïve',
      );
      expect(res.matchedTarget, isTrue);
      expect(
        res.masked,
        'Her _____ assumption seemed _____ even to comparing observers.',
      );

      final partial = ClozeEngine.maskSentence(
        'Comparing metrics helps us compare models cleanly.',
        'compare',
      );
      expect(
        partial.masked,
        'Comparing metrics helps us _____ models cleanly.',
      );
    });

    test('converts a/an before blank to A(n) at sentence start and a(n) inline', () {
      final start = ClozeEngine.maskSentence(
        'An accurate transcription captures every sound.',
        'accurate',
      );
      expect(start.masked, 'A(n) _____ transcription captures every sound.');
      expect(start.isBlankAtStart, isFalse);

      final inline = ClozeEngine.maskSentence(
        'She wrote an accurate report and a accurate summary.',
        'accurate',
      );
      expect(inline.masked, 'She wrote a(n) _____ report and a(n) _____ summary.');
    });

    test('capitalizes all 4 choices iff blank starts the sentence', () {
      final targetStart = _word(
        key: 'assiduous',
        level: 'C2',
        pos: 'adjective',
        cloze: 'Assiduous daily practice lifts words into permanent mastery.',
      );
      final targetMid = _word(
        key: 'concise',
        level: 'B2',
        pos: 'adjective',
        cloze: 'Please write a concise summary for the briefing.',
      );
      final pool = [
        targetStart,
        targetMid,
        _word(key: 'fastidious', level: 'C2', pos: 'adjective'),
        _word(key: 'laconic', level: 'C2', pos: 'adjective'),
        _word(key: 'pellucid', level: 'C2', pos: 'adjective'),
        _word(key: 'coherent', level: 'B2', pos: 'adjective'),
        _word(key: 'feasible', level: 'B2', pos: 'adjective'),
        _word(key: 'resilient', level: 'B2', pos: 'adjective'),
      ];

      final qStart = ClozeEngine.buildQuestion(
        target: targetStart,
        candidatePool: pool,
        random: Random(42),
      );
      expect(qStart.isBlankAtStart, isTrue);
      expect(qStart.options.length, 4);
      for (final opt in qStart.options) {
        expect(opt[0], equals(opt[0].toUpperCase()));
      }

      final qMid = ClozeEngine.buildQuestion(
        target: targetMid,
        candidatePool: pool,
        random: Random(42),
      );
      expect(qMid.isBlankAtStart, isFalse);
      for (final opt in qMid.options) {
        expect(opt[0], equals(opt[0].toLowerCase()));
      }
    });
  });

  group('ClozeEngine 3-tier distractor filtering', () {
    test('excludes synonyms, shared 5+ letter stems, and words present in sentence', () {
      final target = _word(
        key: 'compare',
        level: 'B1',
        pos: 'verb',
        synonyms: const ['contrast'],
        cloze: 'Analysts compare quarterly metrics to predict trends.',
      );

      final pool = [
        target,
        // Must be rejected: synonym
        _word(key: 'contrast', level: 'B1', pos: 'verb'),
        // Must be rejected: shared 5+ letter stem ("compa")
        _word(key: 'comparable', level: 'B1', pos: 'verb'),
        // Must be rejected: already appears in sentence
        _word(key: 'predict', level: 'B1', pos: 'verb'),
        // Valid Tier 1 candidates (same level B1, same POS verb, same wordCount 1)
        _word(key: 'achieve', level: 'B1', pos: 'verb'),
        _word(key: 'reduce', level: 'B1', pos: 'verb'),
        // Valid Tier 2 candidate (different level B2, same POS verb, same wordCount 1)
        _word(key: 'sustain', level: 'B2', pos: 'verb'),
        // Valid Tier 3 candidate (noun)
        _word(key: 'catalyst', level: 'C1', pos: 'noun'),
      ];

      final distractors = ClozeEngine.selectDistractors(
        target: target,
        sentence: target.clozeExample!,
        candidatePool: pool,
        count: 3,
        random: Random(7),
      );

      final keys = distractors.map((d) => d.wordKey).toSet();
      expect(keys.length, 3);
      expect(keys, isNot(contains('contrast')));
      expect(keys, isNot(contains('comparable')));
      expect(keys, isNot(contains('predict')));
      expect(keys, containsAll(['achieve', 'reduce', 'sustain']));
    });
  });
}
