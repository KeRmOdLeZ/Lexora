import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../models/word_entry.dart';
import '../services/notification_service.dart';
import '../services/srs_engine.dart';
import '../services/widget_sync_service.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';
import '../widgets/accent_audio_rows.dart';

/// Evening Cloze Test operating strictly on today's new words.
class EveningClozeScreen extends ConsumerStatefulWidget {
  const EveningClozeScreen({super.key});

  @override
  ConsumerState<EveningClozeScreen> createState() => _EveningClozeScreenState();
}

class _EveningClozeScreenState extends ConsumerState<EveningClozeScreen> {
  bool _loading = true;
  bool _submitting = false;
  bool _completed = false;

  DailySession? _session;
  List<ClozeQuestion> _questions = const [];
  int _index = 0;

  int? _selectedOptionIndex;
  int _correctCount = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadClozeSession);
  }

  @override
  void dispose() {
    unawaited(ref.read(audioServiceProvider).stopAll());
    super.dispose();
  }

  Future<void> _loadClozeSession() async {
    final db = ref.read(databaseServiceProvider);
    final session = await db.getOrCreateTodaySession();
    if (!mounted) return;

    if (session == null ||
        session.isReviewOnly ||
        session.eveningWordKeys.isEmpty) {
      setState(() {
        _session = session;
        _completed = true;
        _loading = false;
      });
      return;
    }

    final wordsMap = await db.getWordsByKeys(session.eveningWordKeys);
    final candidatePool = await db.getStudyPoolEntries(limit: 400);
    final rng = Random();

    final questions = <ClozeQuestion>[];
    for (final key in session.eveningWordKeys) {
      final entry = wordsMap[key];
      if (entry != null) {
        questions.add(
          ClozeEngine.buildQuestion(
            target: entry,
            candidatePool: candidatePool,
            random: rng,
          ),
        );
      }
    }

    if (!mounted) return;
    final startIndex = session.eveningIndex.clamp(0, questions.length);
    setState(() {
      _session = session;
      _questions = questions;
      _index = startIndex;
      _correctCount = session.eveningCorrectCount;
      _completed = session.eveningCompleted || startIndex >= questions.length;
      _loading = false;
    });
  }

  void _selectOption(int optionIndex) {
    if (_selectedOptionIndex != null) return;
    setState(() => _selectedOptionIndex = optionIndex);

    final q = _questions[_index];
    final settings = ref.read(settingsControllerProvider);
    if (settings.autoPlayAudio) {
      unawaited(
        ref.read(audioServiceProvider).playWord(
              q.target,
              accent: settings.defaultAccent,
            ),
      );
    }
  }

  Future<void> _continueToNext() async {
    if (_submitting || _selectedOptionIndex == null) return;
    setState(() => _submitting = true);

    try {
      await ref.read(audioServiceProvider).stopAll();
      final q = _questions[_index];
      final isCorrect = _selectedOptionIndex == q.correctIndex;
      final db = ref.read(databaseServiceProvider);

      final updated = await db.recordEveningClozeStepAtomic(
        session: _session!,
        wordKey: q.target.wordKey,
        isCorrect: isCorrect,
      );

      if (updated.eveningCompleted) {
        try {
          await NotificationService.cancelTodayEvening();
        } catch (e) {
          lexoraLog('Evening cancel notification error: $e');
        }
        try {
          await WidgetSyncService.syncFromApp(db, forceRotate: true);
        } catch (e) {
          lexoraLog('Evening widget sync error: $e');
        }
      }
      await ref.read(dashboardControllerProvider.notifier).refresh();
      await ref.read(settingsControllerProvider.notifier).reload();

      if (!mounted) return;
      setState(() {
        _session = updated;
        _index = updated.eveningIndex.clamp(0, _questions.length);
        _correctCount = updated.eveningCorrectCount;
        _selectedOptionIndex = null;
        _completed = updated.eveningCompleted || _index >= _questions.length;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sonuç kaydedilemedi: $e')),
      );
    }
  }

  Future<void> _confirmExit() async {
    if (_completed) {
      if (mounted) context.pop();
      return;
    }
    final shouldLeave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Testten çıkılsın mı?'),
        content: const Text(
          'Yanıtladığın sorular kaydedildi. Akşam Cloze testine daha sonra kaldığın sorudan devam edebilirsin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Devam Et'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Çık'),
          ),
        ],
      ),
    );
    if (shouldLeave == true && mounted) {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: _completed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _confirmExit,
          ),
          title: const Text(
            'Akşam Cloze Testi',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            if (!_loading && !_completed && _questions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    '${_index + 1} / ${_questions.length}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _completed || _index >= _questions.length
                ? _buildCompletion(theme)
                : _buildQuestion(theme, _questions[_index]),
      ),
    );
  }

  Widget _buildQuestion(ThemeData theme, ClozeQuestion q) {
    final answered = _selectedOptionIndex != null;
    final progress = (_index + (answered ? 1 : 0)) / _questions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          minHeight: 4,
          color: LexoraTheme.emeraldBright,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Boşluğa en uygun kelimeyi seç:',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.65),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          answered ? q.originalSentence : q.maskedPrompt,
                          style: theme.textTheme.titleMedium?.copyWith(
                            height: 1.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                for (var i = 0; i < q.options.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildOptionButton(theme, q, i),
                  ),
                ],
                if (answered) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _selectedOptionIndex == q.correctIndex
                                    ? Icons.check_circle_rounded
                                    : Icons.cancel_rounded,
                                color: _selectedOptionIndex == q.correctIndex
                                    ? LexoraTheme.emeraldBright
                                    : LexoraTheme.danger,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  q.target.wordDisplay,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                q.target.primaryPos,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            q.target.meaningEn,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 14),
                          AccentAudioRows(word: q.target, compact: true),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (answered)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: FilledButton(
                onPressed: _submitting ? null : _continueToNext,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Devam Et'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOptionButton(ThemeData theme, ClozeQuestion q, int i) {
    final answered = _selectedOptionIndex != null;
    final isSelected = _selectedOptionIndex == i;
    final isCorrect = i == q.correctIndex;

    Color? borderColor;
    Color? fillColor;
    if (answered) {
      if (isCorrect) {
        borderColor = LexoraTheme.emeraldBright;
        fillColor = LexoraTheme.emeraldBright.withValues(alpha: 0.18);
      } else if (isSelected) {
        borderColor = LexoraTheme.danger;
        fillColor = LexoraTheme.danger.withValues(alpha: 0.18);
      }
    }

    return OutlinedButton(
      onPressed: answered ? null : () => _selectOption(i),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        backgroundColor: fillColor,
        side: borderColor != null ? BorderSide(color: borderColor, width: 1.6) : null,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              q.options[i],
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          if (answered && isCorrect)
            const Icon(Icons.check_rounded, color: LexoraTheme.emeraldBright),
          if (answered && isSelected && !isCorrect)
            const Icon(Icons.close_rounded, color: LexoraTheme.danger),
        ],
      ),
    );
  }

  Widget _buildCompletion(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            size: 72,
            color: LexoraTheme.emeraldBright,
          ),
          const SizedBox(height: 16),
          Text(
            'Akşam Cloze Testi Tamamlandı!',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_correctCount / ${_questions.length} soruyu doğru yanıtladın.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 28),
          SafeArea(
            top: false,
            child: FilledButton(
              onPressed: () => context.pop(),
              child: const Text('Ana Sayfaya Dön'),
            ),
          ),
        ],
      ),
    );
  }
}
