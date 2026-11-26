import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';
import '../services/notification_service.dart';
import '../services/widget_sync_service.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';
import '../widgets/accent_audio_rows.dart';
import '../widgets/clickable_text.dart';

/// 3-Step Morning Study Session (Meaning -> US/UK IPA & Audio -> Examples & Personal Sentence)
/// with atomic SQLite commit on Step 3, `_isSubmitting` guard, `PopScope`, and Extra Practice support.
class MorningSessionScreen extends ConsumerStatefulWidget {
  const MorningSessionScreen({
    super.key,
    this.isExtraPractice = false,
  });

  final bool isExtraPractice;

  @override
  ConsumerState<MorningSessionScreen> createState() =>
      _MorningSessionScreenState();
}

class _MorningSessionScreenState extends ConsumerState<MorningSessionScreen> {
  bool _loading = true;
  bool _isSubmitting = false;
  bool _completed = false;

  DailySession? _session;
  List<WordEntry> _words = const [];
  int _index = 0;

  // Step 1: Meaning, Step 2: Pronunciation, Step 3: Examples & Sentence
  int _step = 1;
  bool _meaningRevealed = false;
  bool _knewMeaning = false;
  bool _knewPronunciation = false;
  int _knownCountLocal = 0;

  final TextEditingController _sentenceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadSession);
  }

  @override
  void dispose() {
    _sentenceController.dispose();
    unawaited(ref.read(audioServiceProvider).stopAll());
    super.dispose();
  }

  Future<void> _loadSession() async {
    final db = ref.read(databaseServiceProvider);

    if (widget.isExtraPractice) {
      final practiceWords = await db.getExtraPracticeWords(count: 7);
      if (!mounted) return;
      setState(() {
        _words = practiceWords;
        _index = 0;
        _completed = practiceWords.isEmpty;
        _loading = false;
      });
      await _prefillSentenceForCurrent();
      return;
    }

    final session = await db.getOrCreateTodaySession();
    if (!mounted) return;
    if (session == null || session.morningWordKeys.isEmpty) {
      setState(() {
        _session = session;
        _completed = true;
        _loading = false;
      });
      return;
    }

    final wordsMap = await db.getWordsByKeys(session.morningWordKeys);
    final orderedWords = <WordEntry>[];
    for (final k in session.morningWordKeys) {
      final w = wordsMap[k];
      if (w != null) orderedWords.add(w);
    }

    if (!mounted) return;
    final startIndex = session.morningIndex.clamp(0, orderedWords.length);
    setState(() {
      _session = session;
      _words = orderedWords;
      _index = startIndex;
      _knownCountLocal = session.morningKnownCount;
      _completed = session.morningCompleted || startIndex >= orderedWords.length;
      _loading = false;
    });
    await _prefillSentenceForCurrent();
  }

  Future<void> _prefillSentenceForCurrent() async {
    if (_completed || _index >= _words.length) return;
    final current = _words[_index];
    final prog =
        await ref.read(databaseServiceProvider).getProgressByKey(current.wordKey);
    if (!mounted) return;
    _sentenceController.text = prog?.userSentence ?? '';
  }

  void _recordStep1(bool knew) {
    setState(() {
      _knewMeaning = knew;
      _step = 2;
    });
    final settings = ref.read(settingsControllerProvider);
    if (settings.autoPlayAudio && _index < _words.length) {
      unawaited(
        ref.read(audioServiceProvider).playWord(
              _words[_index],
              accent: settings.defaultAccent,
            ),
      );
    }
  }

  void _recordStep2(bool knew) {
    setState(() {
      _knewPronunciation = knew;
      _step = 3;
    });
  }

  Future<void> _commitStep3AndAdvance() async {
    if (_isSubmitting || _index >= _words.length) return;
    setState(() => _isSubmitting = true);

    try {
      await ref.read(audioServiceProvider).stopAll();
      final word = _words[_index];

      if (widget.isExtraPractice) {
        if (_knewMeaning) _knownCountLocal++;
        final nextIdx = _index + 1;
        if (!mounted) return;
        setState(() {
          _index = nextIdx;
          _step = 1;
          _meaningRevealed = false;
          _completed = nextIdx >= _words.length;
          _isSubmitting = false;
        });
        await _prefillSentenceForCurrent();
        return;
      }

      final db = ref.read(databaseServiceProvider);
      final updated = await db.recordMorningStepAtomic(
        session: _session!,
        wordKey: word.wordKey,
        knewMeaning: _knewMeaning,
        knewPronunciation: _knewPronunciation,
        userSentence: _sentenceController.text,
      );

      if (updated.morningCompleted) {
        try {
          await NotificationService.cancelTodayMorning();
        } catch (e) {
          lexoraLog('Morning cancel notification error: $e');
        }
        try {
          await WidgetSyncService.syncFromApp(db, forceRotate: true);
        } catch (e) {
          lexoraLog('Morning widget sync error: $e');
        }
      }
      await ref.read(dashboardControllerProvider.notifier).refresh();
      await ref.read(settingsControllerProvider.notifier).reload();

      if (!mounted) return;
      setState(() {
        _session = updated;
        _index = updated.morningIndex.clamp(0, _words.length);
        _knownCountLocal = updated.morningKnownCount;
        _step = 1;
        _meaningRevealed = false;
        _completed = updated.morningCompleted || _index >= _words.length;
        _isSubmitting = false;
      });
      await _prefillSentenceForCurrent();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('İlerleme kaydedilemedi: $e')),
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
        title: const Text('Oturumdan çıkılsın mı?'),
        content: Text(
          widget.isExtraPractice
              ? 'Ekstra pratik oturumundan çıkmak istiyor musun?'
              : 'Tamamlanan kelimelerin kaydedildi. Kaldığın yerden daha sonra devam edebilirsin.',
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
        if (!didPop) {
          _confirmExit();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _confirmExit,
          ),
          title: Text(
            widget.isExtraPractice ? 'Ekstra Pratik' : 'Sabah Oturumu',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            if (!_loading && !_completed && _words.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    '${_index + 1} / ${_words.length}',
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
            : _completed || _index >= _words.length
                ? _buildCompletion(theme)
                : _buildActiveWord(theme, _words[_index]),
      ),
    );
  }

  Widget _buildActiveWord(ThemeData theme, WordEntry word) {
    final progress = (_index + (_step - 1) / 3) / _words.length;
    final levelColor = LexoraTheme.cefrColor(word.level);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 4),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (word.level != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: levelColor.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  word.level!,
                                  style: TextStyle(
                                    color: levelColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 8),
                            Text(
                              word.primaryPos,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'Adım $_step / 3',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          word.wordDisplay,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                if (_step == 1) ...[
                  if (!_meaningRevealed)
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _meaningRevealed = true),
                      icon: const Icon(Icons.visibility_rounded),
                      label: const Text('İngilizce Anlamı Göster'),
                    )
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'English Meaning',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: LexoraTheme.sapphireBright,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ClickableText(
                              word.meaningEn,
                              currentWordKey: word.wordKey,
                              navDepth: 1,
                              style: theme.textTheme.titleMedium?.copyWith(
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ] else if (_step == 2) ...[
                  Text(
                    'Çift Aksan Telaffuz (US / UK)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  AccentAudioRows(word: word),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: ClickableText(
                        word.meaningEn,
                        currentWordKey: word.wordKey,
                        navDepth: 1,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                      ),
                    ),
                  ),
                ] else ...[
                  // Step 3: Examples, Synonyms, Personal Sentence
                  AccentAudioRows(word: word, compact: true),
                  const SizedBox(height: 14),
                  if (word.examples.isNotEmpty) ...[
                    Text(
                      'Örnek Cümleler',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < word.examples.length; i++) ...[
                              ClickableText(
                                '• ${word.examples[i]}',
                                currentWordKey: word.wordKey,
                                navDepth: 1,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.45,
                                ),
                              ),
                              if (i + 1 < word.examples.length)
                                const SizedBox(height: 10),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (word.synonyms.isNotEmpty) ...[
                    Text(
                      'Eş Anlamlılar',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: word.synonyms.map((syn) {
                        return ActionChip(
                          label: Text(syn),
                          onPressed: () async {
                            final target = await ref
                                .read(databaseServiceProvider)
                                .resolveWordOrInflection(syn);
                            if (!mounted) return;
                            if (target == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('"$syn" sözlükte bulunamadı.'),
                                ),
                              );
                              return;
                            }
                            final encoded = Uri.encodeComponent(target.wordKey);
                            context.push('/word/$encoded?depth=1');
                          },
                        );
                      }).toList(growable: false),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    'Kendi Cümlen (İsteğe Bağlı)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _sentenceController,
                    maxLines: AppConstants.maxUserSentenceLines,
                    maxLength: AppConstants.maxUserSentenceLength,
                    inputFormatters: [
                      BiDiSanitizingInputFormatter(
                        allowNewlines: true,
                        maxLines: AppConstants.maxUserSentenceLines,
                        maxLength: AppConstants.maxUserSentenceLength,
                      ),
                    ],
                    decoration: const InputDecoration(
                      hintText:
                          'Bu kelimeyle akılda kalıcı kendi İngilizce cümleni yaz...',
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
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: _buildBottomActions(),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomActions() {
    if (_step == 1) {
      if (!_meaningRevealed) {
        return FilledButton(
          onPressed: () => setState(() => _meaningRevealed = true),
          child: const Text('Anlamı Göster'),
        );
      }
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _recordStep1(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: LexoraTheme.danger,
                side: const BorderSide(color: LexoraTheme.danger),
              ),
              child: const Text('Bilmiyorum'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: () => _recordStep1(true),
              style: FilledButton.styleFrom(
                backgroundColor: LexoraTheme.emeraldBright,
                foregroundColor: const Color(0xFF061A15),
              ),
              child: const Text('Biliyorum'),
            ),
          ),
        ],
      );
    }

    if (_step == 2) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _recordStep2(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: LexoraTheme.danger,
                side: const BorderSide(color: LexoraTheme.danger),
              ),
              child: const Text('Bilmiyorum'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: () => _recordStep2(true),
              style: FilledButton.styleFrom(
                backgroundColor: LexoraTheme.sapphireBright,
                foregroundColor: const Color(0xFF0A1220),
              ),
              child: const Text('Telaffuzu Biliyorum'),
            ),
          ),
        ],
      );
    }

    return FilledButton(
      onPressed: _isSubmitting ? null : _commitStep3AndAdvance,
      child: _isSubmitting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(_index + 1 >= _words.length ? 'Oturumu Tamamla' : 'Sonraki'),
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
            Icons.check_circle_rounded,
            size: 72,
            color: LexoraTheme.emeraldBright,
          ),
          const SizedBox(height: 16),
          Text(
            widget.isExtraPractice
                ? 'Ekstra Pratik Tamamlandı'
                : 'Sabah Oturumu Tamamlandı!',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_knownCountLocal / ${_words.length} kelimenin anlamını doğrudan bildin.',
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
