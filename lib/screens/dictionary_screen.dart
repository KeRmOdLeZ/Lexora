import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';

/// Instant two-tier B-tree offline dictionary with 150ms debounce, `_searchSeq` race guard,
/// CEFR chips, `ScrollViewKeyboardDismissBehavior.onDrag`, recent searches, and B1–C2 browse list.
class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({super.key});

  @override
  ConsumerState<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends ConsumerState<DictionaryScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  int _searchSeq = 0;

  String? _levelFilter; // null = Tümü
  bool _searching = false;

  List<SearchResultItem> _results = const [];
  List<String> _recentSearches = const [];
  List<WordEntry> _popularBrowse = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadIdleData);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadIdleData() async {
    final db = ref.read(databaseServiceProvider);
    final recent = await db.getRecentSearches();
    final browse = await db.getPopularBrowseWords(
      levelFilter: _levelFilter,
      limit: 30,
    );
    if (!mounted) return;
    setState(() {
      _recentSearches = recent;
      _popularBrowse = browse;
    });
  }

  void _onQueryChanged(String raw) {
    _debounce?.cancel();
    final trimmed = TextNormalizer.normalizeQuery(raw);
    if (trimmed.isEmpty) {
      _searchSeq++;
      setState(() {
        _searching = false;
        _results = const [];
      });
      _loadIdleData();
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 150), () {
      _executeSearch(trimmed);
    });
  }

  Future<void> _executeSearch(String query) async {
    final seq = ++_searchSeq;
    setState(() => _searching = true);

    final db = ref.read(databaseServiceProvider);
    final hits = await db.searchWords(query, levelFilter: _levelFilter);
    if (!mounted || seq != _searchSeq) return;

    setState(() {
      _results = hits;
      _searching = false;
    });
  }

  Future<void> _onSubmitted(String raw) async {
    final norm = TextNormalizer.normalizeQuery(raw);
    if (norm.isEmpty) return;
    await ref.read(databaseServiceProvider).addRecentSearch(norm);
    await _executeSearch(norm);
    final recent = await ref.read(databaseServiceProvider).getRecentSearches();
    if (mounted) {
      setState(() => _recentSearches = recent);
    }
  }

  Future<void> _openWord(WordEntry entry, {bool recordSearch = false}) async {
    if (recordSearch) {
      await ref.read(databaseServiceProvider).addRecentSearch(entry.wordKey);
      final recent =
          await ref.read(databaseServiceProvider).getRecentSearches();
      if (mounted) setState(() => _recentSearches = recent);
    }
    if (!mounted) return;
    final encoded = Uri.encodeComponent(entry.wordKey);
    context.push('/word/$encoded?depth=1');
  }

  void _selectLevelFilter(String? level) {
    setState(() => _levelFilter = level);
    final norm = TextNormalizer.normalizeQuery(_searchController.text);
    if (norm.isEmpty) {
      _loadIdleData();
    } else {
      _executeSearch(norm);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasQuery =
        TextNormalizer.normalizeQuery(_searchController.text).isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sözlük',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              inputFormatters: [
                BiDiSanitizingInputFormatter(
                  allowNewlines: false,
                  maxLength: 64,
                ),
              ],
              onChanged: _onQueryChanged,
              onSubmitted: _onSubmitted,
              decoration: InputDecoration(
                hintText: 'İngilizce kelime veya çekim ara (örn. compared)...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
              ),
            ),
          ),

          // CEFR filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Tümü'),
                  selected: _levelFilter == null,
                  onSelected: (_) => _selectLevelFilter(null),
                ),
                const SizedBox(width: 8),
                for (final lvl in AppConstants.allCefrLevels) ...[
                  ChoiceChip(
                    label: Text(lvl),
                    selected: _levelFilter == lvl,
                    onSelected: (_) => _selectLevelFilter(lvl),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),

          if (_searching) const LinearProgressIndicator(minHeight: 2),

          Expanded(
            child: hasQuery
                ? _buildSearchResults(theme)
                : _buildIdleView(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(ThemeData theme) {
    if (_results.isEmpty && !_searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Eşleşen kelime bulunamadı.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = _results[index];
        return _WordResultTile(
          entry: item.entry,
          matchedForm: item.matchedForm,
          onTap: () => _openWord(item.entry, recordSearch: true),
        );
      },
    );
  }

  Widget _buildIdleView(ThemeData theme) {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
      children: [
        if (_recentSearches.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Son Aramalar',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextButton(
                onPressed: () async {
                  await ref.read(databaseServiceProvider).clearRecentSearches();
                  if (mounted) setState(() => _recentSearches = const []);
                },
                child: const Text('Geçmişi Temizle'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _recentSearches.map((term) {
              return ActionChip(
                avatar: const Icon(Icons.history_rounded, size: 16),
                label: Text(term),
                onPressed: () {
                  _searchController.text = term;
                  _searchController.selection = TextSelection.collapsed(
                    offset: term.length,
                  );
                  _executeSearch(term);
                },
              );
            }).toList(growable: false),
          ),
          const SizedBox(height: 20),
        ],
        Text(
          _levelFilter == null
              ? 'B1–C2 Popüler Göz At'
              : '$_levelFilter Seviyesi Kelimeler',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        for (final entry in _popularBrowse) ...[
          _WordResultTile(
            entry: entry,
            matchedForm: null,
            onTap: () => _openWord(entry, recordSearch: false),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _WordResultTile extends StatelessWidget {
  const _WordResultTile({
    required this.entry,
    required this.matchedForm,
    required this.onTap,
  });

  final WordEntry entry;
  final String? matchedForm;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = LexoraTheme.cefrColor(entry.level);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        title: Row(
          children: [
            Expanded(
              child: Text(
                entry.wordDisplay,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            if (entry.level != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.level!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (matchedForm != null) ...[
              const SizedBox(height: 3),
              Text(
                '$matchedForm → ${entry.wordDisplay}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: LexoraTheme.emeraldBright,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              entry.meaningEn,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
