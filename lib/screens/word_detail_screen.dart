import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';
import '../widgets/accent_audio_rows.dart';
import '../widgets/clickable_text.dart';

/// Rich monolingual Word Detail view supporting ClickableText navigation up to depth 15,
/// single-tap home `X` escape button when `depth > 1`, stacked US/UK audio rows,
/// inflected `Forms:` list, clickable synonym chips, and personal note / learning list save.
class WordDetailScreen extends ConsumerStatefulWidget {
  const WordDetailScreen({
    super.key,
    required this.wordKey,
    this.navDepth = 1,
  });

  final String wordKey;
  final int navDepth;

  @override
  ConsumerState<WordDetailScreen> createState() => _WordDetailScreenState();
}

class _WordDetailScreenState extends ConsumerState<WordDetailScreen> {
  bool _loading = true;
  bool _savingNote = false;

  WordEntry? _word;
  List<String> _forms = const [];
  UserProgress? _progress;

  final TextEditingController _sentenceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadWord);
  }

  @override
  void dispose() {
    _sentenceController.dispose();
    unawaited(ref.read(audioServiceProvider).stopAll());
    super.dispose();
  }

  Future<void> _loadWord() async {
    final db = ref.read(databaseServiceProvider);
    final entry = await db.resolveWordOrInflection(widget.wordKey);
    if (!mounted) return;
    if (entry == null) {
      setState(() {
        _word = null;
        _loading = false;
      });
      return;
    }

    final forms = await db.getFormsForWord(entry.wordKey);
    final progress = await db.getProgressByKey(entry.wordKey);
    if (!mounted) return;

    _sentenceController.text = progress?.userSentence ?? '';
    setState(() {
      _word = entry;
      _forms = forms;
      _progress = progress;
      _loading = false;
    });
  }

  Future<void> _saveToLearningList() async {
    final w = _word;
    if (w == null || _savingNote) return;
    setState(() => _savingNote = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.addOrUpdateManualWord(
        wordKey: w.wordKey,
        userSentence: _sentenceController.text,
      );
      final updated = await db.getProgressByKey(w.wordKey);
      await ref.read(dashboardControllerProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _progress = updated;
        _savingNote = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kelime öğrenme listene ve notuna kaydedildi.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingNote = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kaydedilemedi: $e')),
      );
    }
  }

  Future<void> _openSynonym(String syn) async {
    final target =
        await ref.read(databaseServiceProvider).resolveWordOrInflection(syn);
    if (!mounted) return;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$syn" sözlükte bulunamadı.')),
      );
      return;
    }
    if (target.wordKey == _word?.wordKey) return;

    final encoded = Uri.encodeComponent(target.wordKey);
    final nextDepth = widget.navDepth + 1;
    final route = '/word/$encoded?depth=$nextDepth';
    if (widget.navDepth >= AppConstants.maxNavDepth) {
      context.pushReplacement(route);
    } else {
      context.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final word = _word;

    return Scaffold(
      appBar: AppBar(
        leading: widget.navDepth > 1
            ? IconButton(
                tooltip: 'Ana ekrana dön',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => context.go('/dashboard'),
              )
            : null,
        title: Text(
          word?.wordDisplay ?? widget.wordKey,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (widget.navDepth > 1)
            IconButton(
              tooltip: 'Önceki kelime',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {
                if (context.canPop()) context.pop();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : word == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      '"${widget.wordKey}" sözlükte bulunamadı.',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    // Headword header
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (word.level != null) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: LexoraTheme.cefrColor(word.level)
                                          .withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      word.level!,
                                      style: TextStyle(
                                        color: LexoraTheme.cefrColor(word.level),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  word.primaryPos,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    fontStyle: FontStyle.italic,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.72),
                                  ),
                                ),
                                const Spacer(),
                                if (_progress != null)
                                  Chip(
                                    label: Text('Skor ${_progress!.score}'),
                                    visualDensity: VisualDensity.compact,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              word.wordDisplay,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            if (_forms.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Forms: ${_forms.join(', ')}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Stacked US / UK pronunciation rows
                    AccentAudioRows(word: word),
                    const SizedBox(height: 18),

                    // Meanings / Senses (ClickableText)
                    Text(
                      'Anlamlar',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (word.senses.isEmpty)
                              ClickableText(
                                word.meaningEn,
                                currentWordKey: word.wordKey,
                                navDepth: widget.navDepth,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.45,
                                ),
                              )
                            else
                              for (var gIdx = 0;
                                  gIdx < word.senses.length;
                                  gIdx++) ...[
                                Text(
                                  word.senses[gIdx].pos,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: LexoraTheme.sapphireBright,
                                    fontWeight: FontWeight.w700,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                for (var dIdx = 0;
                                    dIdx < word.senses[gIdx].definitions.length;
                                    dIdx++) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: ClickableText(
                                      '${dIdx + 1}. ${word.senses[gIdx].definitions[dIdx]}',
                                      currentWordKey: word.wordKey,
                                      navDepth: widget.navDepth,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        height: 1.45,
                                      ),
                                    ),
                                  ),
                                ],
                                if (gIdx + 1 < word.senses.length)
                                  const Divider(height: 18),
                              ],
                          ],
                        ),
                      ),
                    ),

                    // Examples
                    if (word.examples.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        'Örnek Cümleler',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
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
                                  navDepth: widget.navDepth,
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
                    ],

                    // Clickable Synonym chips
                    if (word.synonyms.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        'Eş Anlamlılar',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: word.synonyms.map((syn) {
                          return ActionChip(
                            label: Text(syn),
                            onPressed: () => _openSynonym(syn),
                          );
                        }).toList(growable: false),
                      ),
                    ],

                    // Learning list + personal sentence
                    const SizedBox(height: 20),
                    Text(
                      'Öğrenme Listesi & Kişisel Not',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                                hintText: 'Kendi örnek cümleni veya notunu yaz...',
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _savingNote ? null : _saveToLearningList,
                              icon: Icon(
                                _progress == null
                                    ? Icons.bookmark_add_rounded
                                    : Icons.save_rounded,
                              ),
                              label: Text(
                                _progress == null
                                    ? 'Öğrenme Listesine Ekle'
                                    : 'Notu Güncelle',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
