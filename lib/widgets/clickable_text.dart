import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/text_normalizer.dart';
import '../state/app_providers.dart';

/// Renders English prose where only Latin/numeric word tokens are tappable,
/// ignoring the active screen's own `currentWordKey`, resolving `words -> word_forms -> strip 's`,
/// and enforcing a maximum navigation stack depth of 15.
class ClickableText extends ConsumerStatefulWidget {
  const ClickableText(
    this.text, {
    super.key,
    this.style,
    this.currentWordKey,
    this.navDepth = 0,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final String? currentWordKey;
  final int navDepth;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  ConsumerState<ClickableText> createState() => _ClickableTextState();
}

class _ClickableTextState extends ConsumerState<ClickableText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _onWordTap(String rawToken) async {
    final normalized = TextNormalizer.normalizeQuery(rawToken);
    if (normalized.isEmpty) return;

    // Ignore active screen's own headword
    if (widget.currentWordKey != null &&
        normalized == TextNormalizer.normalizeQuery(widget.currentWordKey!)) {
      return;
    }

    final db = ref.read(databaseServiceProvider);
    final entry = await db.resolveWordOrInflection(rawToken);
    if (!mounted) return;

    if (entry == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('"$rawToken" sözlükte bulunamadı.'),
            duration: const Duration(seconds: 2),
          ),
        );
      return;
    }

    if (widget.currentWordKey != null &&
        entry.wordKey == TextNormalizer.normalizeQuery(widget.currentWordKey!)) {
      return;
    }

    final encodedKey = Uri.encodeComponent(entry.wordKey);
    final nextDepth = widget.navDepth + 1;
    final route = '/word/$encodedKey?depth=$nextDepth';

    if (widget.navDepth >= AppConstants.maxNavDepth) {
      context.pushReplacement(route);
    } else {
      context.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();

    final baseStyle = widget.style ?? Theme.of(context).textTheme.bodyMedium;
    final activeNorm = widget.currentWordKey != null
        ? TextNormalizer.normalizeQuery(widget.currentWordKey!)
        : null;

    final spans = <InlineSpan>[];
    final matches = TextNormalizer.clickableWordRegex.allMatches(widget.text);
    var cursor = 0;

    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      final tokenNorm = TextNormalizer.normalizeQuery(token);
      final isSelf = activeNorm != null && tokenNorm == activeNorm;

      if (isSelf) {
        spans.add(
          TextSpan(
            text: token,
            style: baseStyle?.copyWith(fontWeight: FontWeight.w600),
          ),
        );
      } else {
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            _onWordTap(token);
          };
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: token,
            recognizer: recognizer,
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow ?? TextOverflow.clip,
    );
  }
}
