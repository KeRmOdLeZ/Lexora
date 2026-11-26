import 'package:flutter/services.dart';

/// Central query normalization, B-tree prefix upper-bound computation,
/// BiDi/control sanitization, and clickable token extraction.
abstract final class TextNormalizer {
  // C0/C1 control characters + BiDi isolation/override/mark characters.
  static final RegExp _controlAndBidiRegex = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  // Control characters excluding newline (\n) for multi-line user sentences.
  static final RegExp _controlExceptNewlineAndBidiRegex = RegExp(
    r'[\x00-\x09\x0B-\x1F\x7F-\x9F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  static final RegExp _multiSpaceRegex = RegExp(r'\s+');

  /// Tokenizes clickable Latin/numeric words with internal apostrophes/hyphens.
  static final RegExp clickableWordRegex = RegExp(
    r"[\p{Script=Latin}0-9]+(?:['’-][\p{Script=Latin}0-9]+)*",
    unicode: true,
  );

  /// Single source of truth for word_key / search normalization.
  /// Mirrors Python ETL `normalize_query` 1:1.
  static String normalizeQuery(String input) {
    var s = input.trim();
    if (s.isEmpty) return '';

    // Turkish dotted/dotless I normalization + strip combining dot above
    s = s
        .replaceAll('İ', 'i')
        .replaceAll('ı', 'i')
        .replaceAll('\u0307', '')
        .toLowerCase();

    // Curly quotes and apostrophes -> ASCII
    s = s
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u201A', "'")
        .replaceAll('\u201B', "'")
        .replaceAll('\u2032', "'")
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u201E', '"')
        .replaceAll('\u201F', '"')
        .replaceAll('\u2033', '"');

    // Strip C0/C1 and BiDi formatting controls
    s = s.replaceAll(_controlAndBidiRegex, '');

    // Strip non-BMP characters (code points > 0xFFFF)
    final buffer = StringBuffer();
    for (final rune in s.runes) {
      if (rune <= 0xFFFF) {
        buffer.writeCharCode(rune);
      }
    }

    // Collapse consecutive whitespace into a single ASCII space
    return buffer.toString().replaceAll(_multiSpaceRegex, ' ').trim();
  }

  /// Computes exclusive B-tree upper bound (`word_key >= query AND word_key < nextPrefix`)
  /// using Unicode scalar values (`query.runes`), skipping UTF-16 surrogate code points
  /// (`0xD800..0xDFFF`) and carrying safely on `0x10FFFF`.
  /// Returns `null` if no strictly greater Unicode prefix exists.
  static String? nextPrefix(String query) {
    if (query.isEmpty) return null;
    final runes = query.runes.toList(growable: false);

    for (var i = runes.length - 1; i >= 0; i--) {
      var nextRune = runes[i] + 1;
      // Skip UTF-16 surrogate gap (0xD800..0xDFFF) so every scalar value is valid UTF-8/UTF-16.
      if (nextRune >= 0xD800 && nextRune <= 0xDFFF) {
        nextRune = 0xE000;
      }
      if (nextRune <= 0x10FFFF) {
        final out = <int>[
          ...runes.sublist(0, i),
          nextRune,
        ];
        return String.fromCharCodes(out);
      }
    }
    return null;
  }

  /// Sanitizes user-authored text (e.g. `user_sentence`), removing BiDi/control chars,
  /// normalizing line endings, limiting line count and max length.
  static String sanitizeUserSentence(
    String input, {
    int maxLength = 500,
    int maxLines = 3,
  }) {
    var s = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    s = s.replaceAll(_controlExceptNewlineAndBidiRegex, '');

    final lines = s.split('\n');
    if (lines.length > maxLines) {
      s = lines.take(maxLines).join('\n');
    }
    s = s.trim();
    if (s.length > maxLength) {
      s = s.substring(0, maxLength).trimRight();
    }
    return s;
  }

  /// Strips BiDi & C0/C1 characters for single-line text inputs.
  static String stripControlAndBidi(String input, {bool allowNewlines = false}) {
    final normalized = allowNewlines
        ? input.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
        : input;
    return normalized.replaceAll(
      allowNewlines ? _controlExceptNewlineAndBidiRegex : _controlAndBidiRegex,
      '',
    );
  }
}

/// Applied to every TextField in Lexora to block BiDi spoofing and control chars.
class BiDiSanitizingInputFormatter extends TextInputFormatter {
  BiDiSanitizingInputFormatter({
    this.allowNewlines = false,
    this.maxLines,
    this.maxLength,
  });

  final bool allowNewlines;
  final int? maxLines;
  final int? maxLength;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = TextNormalizer.stripControlAndBidi(
      newValue.text,
      allowNewlines: allowNewlines,
    );

    if (allowNewlines && maxLines != null) {
      final parts = text.split('\n');
      if (parts.length > maxLines!) {
        return oldValue;
      }
    }
    if (maxLength != null && text.length > maxLength!) {
      text = text.substring(0, maxLength!);
    }

    if (text == newValue.text) {
      return newValue;
    }

    final selectionIndex = newValue.selection.end.clamp(0, text.length);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: selectionIndex),
    );
  }
}
