import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/word_entry.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';

/// Kelime Defterim — filterable by mastery bucket and sortable by `VocabSortOrder`.
class VocabNotebookScreen extends ConsumerStatefulWidget {
  const VocabNotebookScreen({
    super.key,
    required this.initialBucket,
  });

  final MasteryBucket initialBucket;

  @override
  ConsumerState<VocabNotebookScreen> createState() =>
      _VocabNotebookScreenState();
}

class _VocabNotebookScreenState extends ConsumerState<VocabNotebookScreen> {
  late MasteryBucket _bucket;
  VocabSortOrder _sortOrder = VocabSortOrder.nextReviewAsc;
  bool _loading = true;
  List<VocabNotebookItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _bucket = widget.initialBucket;
    Future.microtask(_loadItems);
  }

  Future<void> _loadItems() async {
    setState(() => _loading = true);
    final db = ref.read(databaseServiceProvider);
    final items = await db.getNotebookItems(
      bucket: _bucket,
      sortOrder: _sortOrder,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Kelime Defterim',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          PopupMenuButton<VocabSortOrder>(
            tooltip: 'Sırala',
            icon: const Icon(Icons.sort_rounded),
            initialValue: _sortOrder,
            onSelected: (next) {
              setState(() => _sortOrder = next);
              _loadItems();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: VocabSortOrder.nextReviewAsc,
                child: Text('Tekrar Tarihine Göre (Yakın)'),
              ),
              PopupMenuItem(
                value: VocabSortOrder.scoreAsc,
                child: Text('Skora Göre (Düşükten Yükseğe)'),
              ),
              PopupMenuItem(
                value: VocabSortOrder.scoreDesc,
                child: Text('Skora Göre (Yüksekten Düşüğe)'),
              ),
              PopupMenuItem(
                value: VocabSortOrder.alphaAsc,
                child: Text('Alfabetik (A–Z)'),
              ),
              PopupMenuItem(
                value: VocabSortOrder.recentDesc,
                child: Text('Son Çalışılanlar'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Row(
              children: [
                _bucketChip(MasteryBucket.all, 'Tümü'),
                const SizedBox(width: 8),
                _bucketChip(MasteryBucket.learning, 'Öğreniliyor (<50)'),
                const SizedBox(width: 8),
                _bucketChip(MasteryBucket.consolidating, 'Pekiştiriliyor (50–84)'),
                const SizedBox(width: 8),
                _bucketChip(MasteryBucket.mastered, 'Ustalaşıldı (≥85)'),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? _buildEmptyState(theme)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final scoreColor = _scoreColor(item.progress.score);
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              onTap: () async {
                                final encoded =
                                    Uri.encodeComponent(item.word.wordKey);
                                await context.push('/word/$encoded?depth=1');
                                if (mounted) _loadItems();
                              },
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.word.wordDisplay,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  if (item.word.level != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: LexoraTheme.cefrColor(
                                          item.word.level,
                                        ).withValues(alpha: 0.18),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        item.word.level!,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: LexoraTheme.cefrColor(
                                            item.word.level,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 4),
                                  Text(
                                    item.word.meaningEn,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Skor: ${item.progress.score}  •  Sonraki tekrar: ${item.progress.nextReviewDate}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scoreColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _bucketChip(MasteryBucket b, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _bucket == b,
      onSelected: (_) {
        setState(() => _bucket = b);
        _loadItems();
      },
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_border_rounded,
              size: 56,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 12),
            Text(
              'Bu kategoride henüz kelime yok',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Sabah oturumlarını tamamladıkça veya sözlükten kelime ekledikçe defterin burada dolacak.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _scoreColor(int score) {
    if (score >= 85) return LexoraTheme.emeraldBright;
    if (score >= 50) return LexoraTheme.sapphireBright;
    return LexoraTheme.amber;
  }
}
