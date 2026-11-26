import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/lexora_theme.dart';

/// Vector Lexora geometric 'L' monogram (open book page + acoustic waves).
class LexoraLogo extends StatelessWidget {
  const LexoraLogo({super.key, this.size = 84});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LexoraLogoPainter(),
      ),
    );
  }
}

class _LexoraLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 108.0;
    canvas.save();
    canvas.scale(scale, scale);

    // Deep night navy rounded square background
    final bgRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4, 4, 100, 100),
      const Radius.circular(24),
    );
    canvas.drawRRect(
      bgRect,
      Paint()..color = LexoraTheme.bgNavyBrand,
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = LexoraTheme.borderDark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // Subtle center glow
    canvas.drawCircle(
      const Offset(54, 52),
      36,
      Paint()..color = const Color(0xFF1D283D).withValues(alpha: 0.45),
    );

    // Under-page emerald leaf
    canvas.drawLine(
      const Offset(42, 74.5),
      const Offset(73, 71),
      Paint()
        ..color = LexoraTheme.emeraldBright
        ..strokeWidth = 4.6
        ..strokeCap = StrokeCap.round,
    );

    // Sapphire horizontal open-book page base of 'L'
    canvas.drawLine(
      const Offset(39.5, 70.5),
      const Offset(72.5, 65.5),
      Paint()
        ..color = LexoraTheme.sapphire
        ..strokeWidth = 10.4
        ..strokeCap = StrokeCap.round,
    );

    // Emerald vertical spine of 'L'
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(33.6, 31, 44.4, 74),
        const Radius.circular(4.4),
      ),
      Paint()..color = LexoraTheme.emerald,
    );

    // Spine fold crease
    canvas.drawLine(
      const Offset(44.4, 65.5),
      const Offset(44.4, 72.5),
      Paint()
        ..color = LexoraTheme.bgNavyBrand
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round,
    );

    // Acoustic wave emission dot
    canvas.drawCircle(
      const Offset(51, 55),
      2.7,
      Paint()..color = LexoraTheme.emeraldBright,
    );

    // Inner sound wave arc
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(48, 58), radius: 12.2),
      -1.32,
      1.10,
      false,
      Paint()
        ..color = LexoraTheme.emeraldBright
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round,
    );

    // Outer sound wave arc
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(48, 58), radius: 20.8),
      -1.36,
      math.pi * 0.39,
      false,
      Paint()
        ..color = LexoraTheme.sapphireBright
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
