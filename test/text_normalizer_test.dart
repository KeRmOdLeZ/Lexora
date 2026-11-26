import 'package:flutter_test/flutter_test.dart';
import 'package:lexora/core/text_normalizer.dart';

void main() {
  group('TextNormalizer.normalizeQuery', () {
    test('normalizes Turkish İ, ı, and combining dot above', () {
      expect(TextNormalizer.normalizeQuery('  İSTANBUL  '), 'istanbul');
      expect(TextNormalizer.normalizeQuery('Kırık'), 'kirik');
      expect(TextNormalizer.normalizeQuery('Işık'), 'işik');
      expect(TextNormalizer.normalizeQuery('İcon\u0307'), 'icon');
    });

    test('preserves accented Latin characters while lowercasing', () {
      expect(TextNormalizer.normalizeQuery('Naïve'), 'naïve');
      expect(TextNormalizer.normalizeQuery('RÉSUMÉ'), 'résumé');
      expect(TextNormalizer.normalizeQuery('  Carry   Out  '), 'carry out');
    });

    test('converts curly quotes and apostrophes to ASCII', () {
      expect(TextNormalizer.normalizeQuery('don’t'), "don't");
      expect(TextNormalizer.normalizeQuery('‘quoted’'), "'quoted'");
      expect(TextNormalizer.normalizeQuery('“hello”'), '"hello"');
    });

    test('strips C0/C1 controls, BiDi overrides, and non-BMP characters', () {
      const poisoned = '\u202Eschedule\u2066\u200F\x00\x1F\x7F 😀🚀';
      expect(TextNormalizer.normalizeQuery(poisoned), 'schedule');
    });
  });

  group('TextNormalizer.nextPrefix & UTF-16 scalar handling', () {
    test('increments ASCII and accented Latin scalar values accurately', () {
      expect(TextNormalizer.nextPrefix('cat'), 'cau');
      expect(TextNormalizer.nextPrefix('compare'), 'comparf');
      expect(TextNormalizer.nextPrefix('naïve'), 'naïvf');
      expect(TextNormalizer.nextPrefix(''), isNull);
    });

    test('skips UTF-16 surrogate gap 0xD800..0xDFFF cleanly', () {
      final boundary = String.fromCharCode(0xD7FF);
      final next = TextNormalizer.nextPrefix('a$boundary');
      expect(next, isNotNull);
      expect(next!.runes.toList(), [0x61, 0xE000]);
    });

    test('increments astral UTF-16 surrogate pairs by Unicode scalar value', () {
      const astral = 'a\u{1F600}';
      final next = TextNormalizer.nextPrefix(astral);
      expect(next, 'a\u{1F601}');
      expect(next!.runes.last, 0x1F601);
    });

    test('carries on U+10FFFF and returns null if prefix overflows', () {
      expect(TextNormalizer.nextPrefix('a\u{10FFFF}'), 'b');
      expect(TextNormalizer.nextPrefix('\u{10FFFF}'), isNull);
    });
  });

  group('BiDiSanitizingInputFormatter & clickableWordRegex', () {
    test('strips BiDi controls and enforces maxLines/maxLength', () {
      final formatter = BiDiSanitizingInputFormatter(
        allowNewlines: true,
        maxLines: 3,
        maxLength: 20,
      );
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '\u202EHello\u200F World'),
      );
      expect(result.text, 'Hello World');

      final tooManyLines = formatter.formatEditUpdate(
        const TextEditingValue(text: 'a\nb\nc'),
        const TextEditingValue(text: 'a\nb\nc\nd'),
      );
      expect(tooManyLines.text, 'a\nb\nc');
    });

    test('tokenizes Latin words with internal apostrophes and hyphens', () {
      final matches = TextNormalizer.clickableWordRegex
          .allMatches("Don't conflate well-known naïve terms!")
          .map((m) => m.group(0))
          .toList();
      expect(matches, ["Don't", 'conflate', 'well-known', 'naïve', 'terms']);
    });
  });
}
