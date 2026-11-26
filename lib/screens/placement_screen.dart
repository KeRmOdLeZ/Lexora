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
import '../widgets/lexora_logo.dart';

class _PlacementQuestion {
  const _PlacementQuestion({
    required this.target,
    required this.level,
    required this.maskedDefinition,
    required this.options,
    required this.correctIndex,
  });

  final WordEntry target;
  final String level;
  final String maskedDefinition;
  final List<String> options;
  final int correctIndex;
}

enum _PlacementPhase { intro, testing, result }

/// 16-question CEFR Placement Test (4 B1, 4 B2, 4 C1, 4 C2) with
/// "Bilmiyorum / Geç", quick manual level pick, Consecutive Mastery Rule,
/// and single atomic SQLite commit.
class PlacementScreen extends ConsumerStatefulWidget {
  const PlacementScreen({super.key});

  @override
  ConsumerState<PlacementScreen> createState() => _PlacementScreenState();
}

class _PlacementScreenState extends ConsumerState<PlacementScreen> {
  _PlacementPhase _phase = _PlacementPhase.intro;
  bool _loadingQuestions = false;
  bool _submitting = false;

  List<_PlacementQuestion> _questions = const [];
  int _currentIndex = 0;

  final List<String> _correctWordKeys = [];
  final Map<String, int> _correctByLevel = {'B1': 0, 'B2': 0, 'C1': 0, 'C2': 0};

  String _recommendedLevel = 'B1';
  String _selectedLevel = 'B1';

  Future<void> _startTest() async {
    setState(() => _loadingQuestions = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final pool = await db.getStudyPoolEntries(limit: 400);
      final rng = Random();

      final built = <_PlacementQuestion>[];
      for (final level in AppConstants.studyCefrLevels) {
        final levelWords = pool.where((w) => w.level == level).toList()
          ..shuffle(rng);
        for (final target in levelWords.take(4)) {
          final maskedDef = ClozeEngine.maskDefinition(
            target.meaningEn,
            target.wordDisplay,
          );
          final distractors = ClozeEngine.selectDistractors(
            target: target,
            sentence: target.meaningEn,
            candidatePool: pool,
            count: 3,
            random: rng,
          );
          final choices = <WordEntry>[target, ...distractors]..shuffle(rng);
          final correctIdx =
              choices.indexWhere((c) => c.wordKey == target.wordKey);
          built.add(
            _PlacementQuestion(
              target: target,
              level: level,
              maskedDefinition: maskedDef,
              options: choices.map((c) => c.wordDisplay).toList(growable: false),
              correctIndex: correctIdx < 0 ? 0 : correctIdx,
            ),
          );
        }
      }

      if (!mounted) return;
      _correctWordKeys.clear();
      _correctByLevel.updateAll((_, _) => 0);

      setState(() {
        _questions = built;
        _currentIndex = 0;
        _phase = built.isEmpty ? _PlacementPhase.result : _PlacementPhase.testing;
        _loadingQuestions = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingQuestions = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Test hazırlanamadı: $e')),
      );
    }
  }

  void _answerCurrent(int? chosenIndex) {
    final q = _questions[_currentIndex];
    final isCorrect = chosenIndex != null && chosenIndex == q.correctIndex;
    if (isCorrect) {
      _correctWordKeys.add(q.target.wordKey);
      _correctByLevel[q.level] = (_correctByLevel[q.level] ?? 0) + 1;
    }

    if (_currentIndex + 1 < _questions.length) {
      setState(() => _currentIndex++);
    } else {
      final rec = SrsEngine.computePlacementStartLevel(
        b1Correct: _correctByLevel['B1'] ?? 0,
        b2Correct: _correctByLevel['B2'] ?? 0,
        c1Correct: _correctByLevel['C1'] ?? 0,
      );
      setState(() {
        _recommendedLevel = rec;
        _selectedLevel = rec;
        _phase = _PlacementPhase.result;
      });
    }
  }

  Future<void> _commitAndFinish({
    required String targetLevel,
    required List<String> correctKeys,
  }) async {
    if (_submitting) return;
    setState(() => _submitting = true);

    try {
      final db = ref.read(databaseServiceProvider);
      await db.commitPlacementAtomic(
        correctWordKeys: correctKeys,
        targetStartLevel: targetLevel,
      );
      ref.read(bootstrapControllerProvider.notifier).markPlacementCompleted();

      await ref.read(settingsControllerProvider.notifier).reload();
      await ref.read(dashboardControllerProvider.notifier).refresh();
      try {
        await NotificationService.syncSevenDaySchedule(db);
      } catch (e) {
        lexoraLog('Placement notification sync error: $e');
      }
      await WidgetSyncService.syncFromApp(db, forceRotate: true);

      if (!mounted) return;
      context.go('/dashboard');
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Seviye kaydedilemedi: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: AnnotatedRegion(
        value: LexoraTheme.overlayStyleFor(theme.brightness),
        child: Scaffold(
          body: SafeArea(
            child: switch (_phase) {
              _PlacementPhase.intro => _buildIntro(context),
              _PlacementPhase.testing => _buildTesting(context),
              _PlacementPhase.result => _buildResult(context),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildIntro(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Center(child: LexoraLogo(size: 76)),
          const SizedBox(height: 20),
          Text(
            'Lexora\'ya Hoş Geldin',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '16 soruluk hızlı seviye testiyle B1–C2 başlangıç noktanı belirleyelim. Doğru bildiğin kelimeler otomatik pekiştirme takvimine alınır.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _loadingQuestions ? null : _startTest,
            icon: _loadingQuestions
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Seviye Testini Başlat (16 Soru)'),
          ),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),
          Text(
            'Seviyemi Kendim Seç',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Testi atlayarak doğrudan başlangıç seviyeni belirleyebilirsin.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 14),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.35,
            children: AppConstants.studyCefrLevels.map((lvl) {
              final accent = LexoraTheme.cefrColor(lvl);
              return OutlinedButton(
                onPressed: _submitting
                    ? null
                    : () => _commitAndFinish(
                          targetLevel: lvl,
                          correctKeys: const [],
                        ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: accent.withValues(alpha: 0.65)),
                ),
                child: Text(
                  '$lvl Başlangıç',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            }).toList(growable: false),
          ),
        ],
      ),
    );
  }

  Widget _buildTesting(BuildContext context) {
    final theme = Theme.of(context);
    final q = _questions[_currentIndex];
    final progress = (_currentIndex + 1) / _questions.length;
    final levelColor = LexoraTheme.cefrColor(q.level);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: levelColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: levelColor.withValues(alpha: 0.6)),
                ),
                child: Text(
                  q.level,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: levelColor,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 7,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_currentIndex + 1}/${_questions.length}',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
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
                          'Bu tanıma uyan kelime hangisi?',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.65),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          q.maskedDefinition,
                          style: theme.textTheme.titleMedium?.copyWith(
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          q.target.primaryPos,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: levelColor,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                for (var i = 0; i < q.options.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: OutlinedButton(
                      onPressed: () => _answerCurrent(i),
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 15,
                        ),
                      ),
                      child: Text(
                        q.options[i],
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: TextButton(
              onPressed: () => _answerCurrent(null),
              child: const Text('Bilmiyorum / Geç'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context) {
    final theme = Theme.of(context);
    final recColor = LexoraTheme.cefrColor(_recommendedLevel);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Icon(
                  Icons.verified_rounded,
                  size: 64,
                  color: recColor,
                ),
                const SizedBox(height: 14),
                Text(
                  'Önerilen Başlangıç Seviyen',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _recommendedLevel,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: recColor,
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: AppConstants.studyCefrLevels.map((lvl) {
                        final count = _correctByLevel[lvl] ?? 0;
                        return Column(
                          children: [
                            Text(
                              lvl,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: LexoraTheme.cefrColor(lvl),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$count / 4',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        );
                      }).toList(growable: false),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'İstersen başlangıç seviyeni aşağıdan değiştirebilirsin:',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: AppConstants.studyCefrLevels.map((lvl) {
                    final selected = _selectedLevel == lvl;
                    return ChoiceChip(
                      label: Text(lvl),
                      selected: selected,
                      onSelected: (_) => setState(() => _selectedLevel = lvl),
                    );
                  }).toList(growable: false),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: FilledButton(
              onPressed: _submitting
                  ? null
                  : () => _commitAndFinish(
                        targetLevel: _selectedLevel,
                        correctKeys: _correctWordKeys,
                      ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('$_selectedLevel Seviyesiyle Başla'),
            ),
          ),
        ),
      ],
    );
  }
}
