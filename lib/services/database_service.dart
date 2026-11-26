import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import '../core/date_utils.dart';
import '../core/text_normalizer.dart';
import '../models/word_entry.dart';
import 'srs_engine.dart';

/// Dual-connection SQLite manager (`user_data.db` read-write + `vocab_dict.db` read-only).
/// Strictly forbids `ATTACH DATABASE` and `LIKE` operators.
class DatabaseService {
  Database? _userDb;
  Database? _dictDb;

  bool get isUserDbOpen => _userDb?.isOpen ?? false;
  bool get isDictDbOpen => _dictDb?.isOpen ?? false;

  /// Splits any list into chunks of at most 500 items for `IN (?, ...)` queries
  /// (`SQLITE_MAX_VARIABLE_NUMBER` protection).
  static List<List<T>> chunkList<T>(
    List<T> items, {
    int chunkSize = AppConstants.sqlInChunkSize,
  }) {
    if (items.isEmpty) return const [];
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = min(i + chunkSize, items.length);
      chunks.add(items.sublist(i, end));
    }
    return chunks;
  }

  static Future<void> _configureUserDb(Database db) async {
    // Exact PRAGMA order using rawQuery (PRAGMAs returning rows).
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.rawQuery('PRAGMA synchronous = NORMAL');
    await db.rawQuery('PRAGMA foreign_keys = ON');
  }

  static Future<void> _createUserDbSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE user_progress (
        word_key TEXT PRIMARY KEY,
        score INTEGER NOT NULL DEFAULT 20,
        next_review_date TEXT NOT NULL,
        review_count INTEGER NOT NULL DEFAULT 0,
        lapse_count INTEGER NOT NULL DEFAULT 0,
        user_sentence TEXT NOT NULL DEFAULT '',
        last_reviewed_at TEXT,
        created_at TEXT NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE media_cache (
        word_key TEXT NOT NULL,
        accent TEXT NOT NULL,
        file_name TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        last_accessed_ms INTEGER NOT NULL,
        PRIMARY KEY (word_key, accent)
      );
    ''');
    await db.execute('''
      CREATE TABLE daily_session (
        session_date TEXT PRIMARY KEY,
        new_word_keys TEXT NOT NULL,
        review_word_keys TEXT NOT NULL,
        morning_word_keys TEXT NOT NULL,
        evening_word_keys TEXT NOT NULL,
        morning_error_keys TEXT NOT NULL DEFAULT '[]',
        morning_index INTEGER NOT NULL DEFAULT 0,
        evening_index INTEGER NOT NULL DEFAULT 0,
        morning_known_count INTEGER NOT NULL DEFAULT 0,
        evening_correct_count INTEGER NOT NULL DEFAULT 0,
        is_review_only INTEGER NOT NULL DEFAULT 0,
        morning_completed INTEGER NOT NULL DEFAULT 0,
        evening_completed INTEGER NOT NULL DEFAULT 0
      );
    ''');
    await db.execute('''
      CREATE TABLE app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');

    await db.execute(
      'CREATE INDEX idx_progress_review ON user_progress(next_review_date, score, word_key);',
    );
    await db.execute(
      'CREATE INDEX idx_progress_score ON user_progress(score, word_key);',
    );
    await db.execute(
      'CREATE INDEX idx_media_lru ON media_cache(last_accessed_ms ASC);',
    );

    final batch = db.batch();
    for (final entry in AppMetaKeys.defaults.entries) {
      batch.insert(
        'app_meta',
        {'key': entry.key, 'value': entry.value},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Opens read-write `user_data.db` on the main isolate.
  Future<Database> openUserDb() async {
    if (_userDb != null && _userDb!.isOpen) return _userDb!;
    final dbDir = await getDatabasesPath();
    final userPath = p.join(dbDir, AppConstants.userDbName);
    _userDb = await openDatabase(
      userPath,
      version: 1,
      onConfigure: _configureUserDb,
      onCreate: _createUserDbSchema,
    );
    return _userDb!;
  }

  /// Opens read-only `vocab_dict.db` strictly without version/onCreate/onUpgrade/onConfigure.
  Future<Database> openDictDb(String dictPath) async {
    if (_dictDb != null && _dictDb!.isOpen) return _dictDb!;
    _dictDb = await openDatabase(
      dictPath,
      readOnly: true,
    );
    return _dictDb!;
  }

  Future<void> closeDictDb() async {
    final db = _dictDb;
    _dictDb = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }

  Future<void> closeAll() async {
    await closeDictDb();
    final udb = _userDb;
    _userDb = null;
    if (udb != null && udb.isOpen) {
      await udb.close();
    }
  }

  /// Background isolate helper (`workmanager` / `home_widget`): opens `user_data.db`
  /// strictly with `singleInstance: false`.
  static Future<Database> openUserDbForBackground() async {
    final dbDir = await getDatabasesPath();
    final userPath = p.join(dbDir, AppConstants.userDbName);
    return openDatabase(
      userPath,
      version: 1,
      singleInstance: false,
      onConfigure: _configureUserDb,
      onCreate: _createUserDbSchema,
    );
  }

  /// Background isolate helper: verifies `dict_ready == '1'`, file existence, and absence of `.tmp`,
  /// then opens `vocab_dict.db` strictly via `openDatabase(path, readOnly: true, singleInstance: false)`.
  static Future<Database?> openDictDbForBackground(Database userDb) async {
    final metaRows = await userDb.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [AppMetaKeys.dictReady],
      limit: 1,
    );
    final isReady = metaRows.isNotEmpty && metaRows.first['value'] == '1';
    if (!isReady) return null;

    final dbDir = await getDatabasesPath();
    final dictPath = p.join(dbDir, AppConstants.dictDbName);
    final tmpPath = '$dictPath.tmp';
    if (!File(dictPath).existsSync() || File(tmpPath).existsSync()) {
      return null;
    }

    return openDatabase(
      dictPath,
      readOnly: true,
      singleInstance: false,
    );
  }

  Database get _requireUserDb {
    final db = _userDb;
    if (db == null || !db.isOpen) {
      throw StateError('user_data.db is not open.');
    }
    return db;
  }

  Database get _requireDictDb {
    final db = _dictDb;
    if (db == null || !db.isOpen) {
      throw StateError('vocab_dict.db is not open.');
    }
    return db;
  }

  // ---------------------------------------------------------------------------
  // app_meta
  // ---------------------------------------------------------------------------

  Future<String> getMeta(String key, {String fallback = ''}) async {
    final rows = await _requireUserDb.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return AppMetaKeys.defaults[key] ?? fallback;
    }
    return (rows.first['value'] as String?) ?? fallback;
  }

  Future<Map<String, String>> getAllMeta() async {
    final rows = await _requireUserDb.query('app_meta');
    final map = Map<String, String>.from(AppMetaKeys.defaults);
    for (final row in rows) {
      final k = row['key'] as String?;
      final v = row['value'] as String?;
      if (k != null && v != null) {
        map[k] = v;
      }
    }
    return map;
  }

  Future<void> setMeta(String key, String value) async {
    await _requireUserDb.insert(
      'app_meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setMetaBatch(Map<String, String> values) async {
    await _requireUserDb.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in values.entries) {
        batch.insert(
          'app_meta',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ---------------------------------------------------------------------------
  // Dictionary reads & two-tier <10ms search (NO LIKE, B-tree range only)
  // ---------------------------------------------------------------------------

  Future<WordEntry?> getWordByKey(String rawKey) async {
    final key = TextNormalizer.normalizeQuery(rawKey);
    if (key.isEmpty) return null;
    final rows = await _requireDictDb.query(
      'words',
      where: 'word_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WordEntry.fromMap(rows.first);
  }

  Future<Map<String, WordEntry>> getWordsByKeys(List<String> keys) async {
    if (keys.isEmpty) return const {};
    final unique = keys.toSet().toList(growable: false);
    final result = <String, WordEntry>{};
    for (final chunk in chunkList(unique)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _requireDictDb.rawQuery(
        'SELECT * FROM words WHERE word_key IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        final entry = WordEntry.fromMap(row);
        result[entry.wordKey] = entry;
      }
    }
    return result;
  }

  Future<List<String>> getFormsForWord(String wordKey) async {
    final rows = await _requireDictDb.query(
      'word_forms',
      columns: ['form'],
      where: 'word_key = ?',
      whereArgs: [wordKey],
      limit: 30,
    );
    return rows.map((r) => r['form'] as String).toList(growable: false);
  }

  /// Resolves tapped word in ClickableText: `words` -> `word_forms` -> strip `'s` retry.
  Future<WordEntry?> resolveWordOrInflection(String rawToken) async {
    final norm = TextNormalizer.normalizeQuery(rawToken);
    if (norm.isEmpty) return null;

    final direct = await _resolveDirectOrForm(norm);
    if (direct != null) return direct;

    // Strip English possessive `'s` or trailing apostrophe and retry
    if (norm.endsWith("'s") && norm.length > 2) {
      return _resolveDirectOrForm(norm.substring(0, norm.length - 2));
    }
    if (norm.endsWith("'") && norm.length > 1) {
      return _resolveDirectOrForm(norm.substring(0, norm.length - 1));
    }
    return null;
  }

  Future<WordEntry?> _resolveDirectOrForm(String normalized) async {
    final exact = await getWordByKey(normalized);
    if (exact != null) return exact;

    final formRows = await _requireDictDb.query(
      'word_forms',
      columns: ['word_key'],
      where: 'form = ?',
      whereArgs: [normalized],
      limit: 5,
    );
    if (formRows.isEmpty) return null;

    final rootKeys = formRows
        .map((r) => r['word_key'] as String)
        .toList(growable: false);
    final roots = await getWordsByKeys(rootKeys);
    if (roots.isEmpty) return null;

    // Prefer CEFR-tagged root, then shortest
    final list = roots.values.toList();
    list.sort((a, b) {
      final aCefr = a.level != null ? 0 : 1;
      final bCefr = b.level != null ? 0 : 1;
      if (aCefr != bCefr) return aCefr.compareTo(bCefr);
      return a.wordKey.length.compareTo(b.wordKey.length);
    });
    return list.first;
  }

  /// Two-tier B-tree prefix search (< 10 ms at 1M+ rows, zero LIKE).
  Future<List<SearchResultItem>> searchWords(
    String rawQuery, {
    String? levelFilter,
  }) async {
    final query = TextNormalizer.normalizeQuery(rawQuery);
    if (query.isEmpty) return const [];

    final upperBound = TextNormalizer.nextPrefix(query);
    final dictDb = _requireDictDb;

    final byKey = <String, SearchResultItem>{};

    void addEntries(List<Map<String, Object?>> rows) {
      for (final row in rows) {
        final entry = WordEntry.fromMap(row);
        byKey.putIfAbsent(
          entry.wordKey,
          () => SearchResultItem(entry: entry),
        );
      }
    }

    if (levelFilter != null && AppConstants.allCefrLevels.contains(levelFilter)) {
      // Filtered mode: idx_cefr_level_key (LIMIT 50) + word_forms (LIMIT 15) filtered by level.
      final headwordRows = upperBound != null
          ? await dictDb.rawQuery(
              'SELECT * FROM words WHERE level = ? AND word_key >= ? AND word_key < ? LIMIT 50',
              [levelFilter, query, upperBound],
            )
          : await dictDb.rawQuery(
              'SELECT * FROM words WHERE level = ? AND word_key >= ? LIMIT 50',
              [levelFilter, query],
            );
      addEntries(headwordRows);

      final formRows = upperBound != null
          ? await dictDb.rawQuery(
              'SELECT form, word_key FROM word_forms WHERE form >= ? AND form < ? LIMIT 15',
              [query, upperBound],
            )
          : await dictDb.rawQuery(
              'SELECT form, word_key FROM word_forms WHERE form >= ? LIMIT 15',
              [query],
            );
      if (formRows.isNotEmpty) {
        final rootKeys = formRows
            .map((r) => r['word_key'] as String)
            .where((k) => !byKey.containsKey(k))
            .toList(growable: false);
        final roots = await getWordsByKeys(rootKeys);
        for (final fr in formRows) {
          final form = fr['form'] as String;
          final rootKey = fr['word_key'] as String;
          final root = roots[rootKey];
          if (root != null && root.level == levelFilter && !byKey.containsKey(rootKey)) {
            byKey[rootKey] = SearchResultItem(entry: root, matchedForm: form);
          }
        }
      }
    } else {
      // All mode:
      // Tier 1: idx_cefr_key (LIMIT 50)
      final cefrRows = upperBound != null
          ? await dictDb.rawQuery(
              'SELECT * FROM words WHERE level IS NOT NULL AND word_key >= ? AND word_key < ? LIMIT 50',
              [query, upperBound],
            )
          : await dictDb.rawQuery(
              'SELECT * FROM words WHERE level IS NOT NULL AND word_key >= ? LIMIT 50',
              [query],
            );
      addEntries(cefrRows);

      // Tier 2: full words (NO ORDER BY, LIMIT 50) + word_forms (LIMIT 15)
      if (byKey.length < 50 || query.length >= 2) {
        final fullRows = upperBound != null
            ? await dictDb.rawQuery(
                'SELECT * FROM words WHERE word_key >= ? AND word_key < ? LIMIT 50',
                [query, upperBound],
              )
            : await dictDb.rawQuery(
                'SELECT * FROM words WHERE word_key >= ? LIMIT 50',
                [query],
              );
        addEntries(fullRows);

        final formRows = upperBound != null
            ? await dictDb.rawQuery(
                'SELECT form, word_key FROM word_forms WHERE form >= ? AND form < ? LIMIT 15',
                [query, upperBound],
              )
            : await dictDb.rawQuery(
                'SELECT form, word_key FROM word_forms WHERE form >= ? LIMIT 15',
                [query],
              );
        if (formRows.isNotEmpty) {
          final rootKeys = formRows
              .map((r) => r['word_key'] as String)
              .where((k) => !byKey.containsKey(k))
              .toList(growable: false);
          final roots = await getWordsByKeys(rootKeys);
          for (final fr in formRows) {
            final form = fr['form'] as String;
            final rootKey = fr['word_key'] as String;
            final root = roots[rootKey];
            if (root != null && !byKey.containsKey(rootKey)) {
              byKey[rootKey] = SearchResultItem(entry: root, matchedForm: form);
            }
          }
        }
      }
    }

    // In-memory ranking (< 1 ms): exact match -> CEFR level -> shorter length -> alphabetical
    final results = byKey.values.toList();
    results.sort((a, b) {
      final aExact = (a.entry.wordKey == query || a.matchedForm == query) ? 0 : 1;
      final bExact = (b.entry.wordKey == query || b.matchedForm == query) ? 0 : 1;
      if (aExact != bExact) return aExact.compareTo(bExact);

      final aHeadExact = a.entry.wordKey == query ? 0 : 1;
      final bHeadExact = b.entry.wordKey == query ? 0 : 1;
      if (aHeadExact != bHeadExact) return aHeadExact.compareTo(bHeadExact);

      final aCefrRank = _cefrSortRank(a.entry.level);
      final bCefrRank = _cefrSortRank(b.entry.level);
      if (aCefrRank != bCefrRank) return aCefrRank.compareTo(bCefrRank);

      final lenCmp = a.entry.wordKey.length.compareTo(b.entry.wordKey.length);
      if (lenCmp != 0) return lenCmp;

      return a.entry.wordKey.compareTo(b.entry.wordKey);
    });

    return results.take(60).toList(growable: false);
  }

  static int _cefrSortRank(String? level) {
    if (level == null) return 99;
    final idx = AppConstants.allCefrLevels.indexOf(level);
    return idx < 0 ? 99 : idx;
  }

  /// B1-C2 popular browse list when Dictionary search input is empty.
  Future<List<WordEntry>> getPopularBrowseWords({
    String? levelFilter,
    int limit = 30,
  }) async {
    final dictDb = _requireDictDb;
    final List<Map<String, Object?>> rows;
    if (levelFilter != null && AppConstants.allCefrLevels.contains(levelFilter)) {
      rows = await dictDb.rawQuery(
        'SELECT * FROM words WHERE level = ? LIMIT ?',
        [levelFilter, limit],
      );
    } else {
      rows = await dictDb.rawQuery(
        "SELECT * FROM words WHERE level IN ('B1','B2','C1','C2') AND cloze_example IS NOT NULL LIMIT ?",
        [limit],
      );
    }
    return rows.map(WordEntry.fromMap).toList(growable: false);
  }

  /// Fetches study-eligible word keys for a CEFR level via `idx_study_pool`.
  Future<List<String>> getStudyPoolKeysByLevel(String level) async {
    final rows = await _requireDictDb.rawQuery(
      'SELECT word_key FROM words WHERE level = ? AND cloze_example IS NOT NULL',
      [level],
    );
    return rows.map((r) => r['word_key'] as String).toList(growable: false);
  }

  /// Fetches a balanced, randomized candidate pool across B1..C2 for Cloze,
  /// Placement Test, and Extra Practice via `idx_study_pool`.
  Future<List<WordEntry>> getStudyPoolEntries({int limit = 320}) async {
    final rng = Random();
    final perLevel = max(20, limit ~/ AppConstants.studyCefrLevels.length);
    final sampledKeys = <String>[];

    for (final level in AppConstants.studyCefrLevels) {
      final levelKeys = await getStudyPoolKeysByLevel(level);
      if (levelKeys.isEmpty) continue;
      if (levelKeys.length <= perLevel) {
        sampledKeys.addAll(levelKeys);
      } else {
        // Reservoir-free random sampling without copying huge lists unnecessarily.
        final picked = <int>{};
        while (picked.length < perLevel) {
          picked.add(rng.nextInt(levelKeys.length));
        }
        for (final idx in picked) {
          sampledKeys.add(levelKeys[idx]);
        }
      }
    }

    if (sampledKeys.isEmpty) return const [];
    final entriesMap = await getWordsByKeys(sampledKeys);
    return sampledKeys
        .map((k) => entriesMap[k])
        .whereType<WordEntry>()
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Recent searches (max 20, saved only on result tap or Enter)
  // ---------------------------------------------------------------------------

  Future<List<String>> getRecentSearches() async {
    final raw = await getMeta(AppMetaKeys.recentSearches, fallback: '[]');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .take(AppConstants.maxRecentSearches)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> addRecentSearch(String rawTerm) async {
    final term = TextNormalizer.normalizeQuery(rawTerm);
    if (term.isEmpty) return;
    final current = (await getRecentSearches()).toList();
    current.remove(term);
    current.insert(0, term);
    if (current.length > AppConstants.maxRecentSearches) {
      current.removeRange(AppConstants.maxRecentSearches, current.length);
    }
    await setMeta(AppMetaKeys.recentSearches, jsonEncode(current));
  }

  Future<void> clearRecentSearches() async {
    await setMeta(AppMetaKeys.recentSearches, '[]');
  }

  // ---------------------------------------------------------------------------
  // user_progress
  // ---------------------------------------------------------------------------

  Future<UserProgress?> getProgressByKey(String wordKey) async {
    final rows = await _requireUserDb.query(
      'user_progress',
      where: 'word_key = ?',
      whereArgs: [wordKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UserProgress.fromMap(rows.first);
  }

  Future<Map<String, UserProgress>> getProgressByKeys(List<String> keys) async {
    if (keys.isEmpty) return const {};
    final unique = keys.toSet().toList(growable: false);
    final result = <String, UserProgress>{};
    for (final chunk in chunkList(unique)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _requireUserDb.rawQuery(
        'SELECT * FROM user_progress WHERE word_key IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        final pObj = UserProgress.fromMap(row);
        result[pObj.wordKey] = pObj;
      }
    }
    return result;
  }

  Future<List<UserProgress>> getAllProgress() async {
    final rows = await _requireUserDb.query(
      'user_progress',
      orderBy: 'word_key ASC',
    );
    return rows.map(UserProgress.fromMap).toList(growable: false);
  }

  Future<Set<String>> getAllSeenWordKeys() async {
    final rows = await _requireUserDb.query(
      'user_progress',
      columns: ['word_key'],
    );
    return rows.map((r) => r['word_key'] as String).toSet();
  }

  Future<MasteryCounts> getMasteryCounts() async {
    final rows = await _requireUserDb.rawQuery('''
      SELECT
        SUM(CASE WHEN score < 50 THEN 1 ELSE 0 END) AS learning,
        SUM(CASE WHEN score >= 50 AND score <= 84 THEN 1 ELSE 0 END) AS consolidating,
        SUM(CASE WHEN score >= 85 THEN 1 ELSE 0 END) AS mastered
      FROM user_progress;
    ''');
    if (rows.isEmpty) {
      return const MasteryCounts(learning: 0, consolidating: 0, mastered: 0);
    }
    final r = rows.first;
    return MasteryCounts(
      learning: (r['learning'] as int?) ?? 0,
      consolidating: (r['consolidating'] as int?) ?? 0,
      mastered: (r['mastered'] as int?) ?? 0,
    );
  }

  Future<List<VocabNotebookItem>> getNotebookItems({
    required MasteryBucket bucket,
    required VocabSortOrder sortOrder,
  }) async {
    String? whereClause;
    switch (bucket) {
      case MasteryBucket.all:
        whereClause = null;
      case MasteryBucket.learning:
        whereClause = 'score < 50';
      case MasteryBucket.consolidating:
        whereClause = 'score >= 50 AND score <= 84';
      case MasteryBucket.mastered:
        whereClause = 'score >= 85';
    }

    final String orderBy;
    switch (sortOrder) {
      case VocabSortOrder.nextReviewAsc:
        orderBy = 'next_review_date ASC, score ASC, word_key ASC';
      case VocabSortOrder.scoreAsc:
        orderBy = 'score ASC, word_key ASC';
      case VocabSortOrder.scoreDesc:
        orderBy = 'score DESC, word_key ASC';
      case VocabSortOrder.alphaAsc:
        orderBy = 'word_key ASC';
      case VocabSortOrder.recentDesc:
        orderBy = 'COALESCE(last_reviewed_at, created_at) DESC, word_key ASC';
    }

    final progressRows = await _requireUserDb.query(
      'user_progress',
      where: whereClause,
      orderBy: orderBy,
    );
    if (progressRows.isEmpty) return const [];

    final progressList =
        progressRows.map(UserProgress.fromMap).toList(growable: false);
    final wordsMap = await getWordsByKeys(
      progressList.map((e) => e.wordKey).toList(growable: false),
    );

    final items = <VocabNotebookItem>[];
    for (final prog in progressList) {
      final word = wordsMap[prog.wordKey];
      if (word != null) {
        items.add(VocabNotebookItem(progress: prog, word: word));
      }
    }
    return items;
  }

  /// Adds a word manually to the user's learning list (or updates its personal sentence).
  Future<void> addOrUpdateManualWord({
    required String wordKey,
    required String userSentence,
  }) async {
    final cleanSentence = TextNormalizer.sanitizeUserSentence(
      userSentence,
      maxLength: AppConstants.maxUserSentenceLength,
      maxLines: AppConstants.maxUserSentenceLines,
    );
    final today = LexoraDateUtils.todayLocalKey();
    final nowIso = DateTime.now().toIso8601String();
    final existing = await getProgressByKey(wordKey);

    if (existing == null) {
      await _requireUserDb.insert(
        'user_progress',
        {
          'word_key': wordKey,
          'score': AppConstants.initialNewWordScore,
          'next_review_date': LexoraDateUtils.addDaysToDateKey(today, 1),
          'review_count': 0,
          'lapse_count': 0,
          'user_sentence': cleanSentence,
          'last_reviewed_at': null,
          'created_at': nowIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await _requireUserDb.update(
        'user_progress',
        {'user_sentence': cleanSentence},
        where: 'word_key = ?',
        whereArgs: [wordKey],
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Placement Test atomic commit
  // ---------------------------------------------------------------------------

  /// Single atomic transaction:
  /// - Correct words -> `score = 75`, `next_review_date = today + 14d`
  /// - Wrong/skipped words -> NOT inserted into `user_progress`
  /// - Sets `target_start_level` and `placement_completed = 'true'`
  Future<void> commitPlacementAtomic({
    required List<String> correctWordKeys,
    required String targetStartLevel,
  }) async {
    final today = LexoraDateUtils.todayLocalKey();
    final nextReview = LexoraDateUtils.addDaysToDateKey(
      today,
      AppConstants.placementCorrectIntervalDays,
    );
    final nowIso = DateTime.now().toIso8601String();

    await _requireUserDb.transaction((txn) async {
      final batch = txn.batch();
      for (final key in correctWordKeys.toSet()) {
        batch.insert(
          'user_progress',
          {
            'word_key': key,
            'score': AppConstants.placementCorrectScore,
            'next_review_date': nextReview,
            'review_count': 1,
            'lapse_count': 0,
            'user_sentence': '',
            'last_reviewed_at': nowIso,
            'created_at': nowIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert(
        'app_meta',
        {'key': AppMetaKeys.targetStartLevel, 'value': targetStartLevel},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      batch.insert(
        'app_meta',
        {'key': AppMetaKeys.placementCompleted, 'value': 'true'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
  }

  // ---------------------------------------------------------------------------
  // Daily Session generation & atomic progress recording
  // ---------------------------------------------------------------------------

  Future<DailySession?> getDailySession(String sessionDate) async {
    final rows = await _requireUserDb.query(
      'daily_session',
      where: 'session_date = ?',
      whereArgs: [sessionDate],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DailySession.fromMap(rows.first);
  }

  /// Generates (or loads frozen) `daily_session` for today.
  /// Strictly returns `null` if placement test has not been completed yet.
  Future<DailySession?> getOrCreateTodaySession({Random? random}) async {
    final placementDone = await getMeta(AppMetaKeys.placementCompleted);
    if (placementDone != 'true') return null;

    final today = LexoraDateUtils.todayLocalKey();
    final existing = await getDailySession(today);
    if (existing != null) return existing;

    final rng = random ?? Random();

    // 1) Overdue reviews from user_data.db (LIMIT 25), filtering orphans not in vocab_dict.db
    final overdueRows = await _requireUserDb.rawQuery(
      '''
      SELECT word_key FROM user_progress
      WHERE next_review_date <= ?
      ORDER BY score ASC, next_review_date ASC, word_key ASC
      LIMIT ?
      ''',
      [today, AppConstants.maxOverdueReviewsPerDay],
    );
    final rawOverdueKeys =
        overdueRows.map((r) => r['word_key'] as String).toList(growable: false);
    final validOverdueMap = await getWordsByKeys(rawOverdueKeys);
    final reviewKeys = rawOverdueKeys
        .where(validOverdueMap.containsKey)
        .toList(growable: false);

    // Check total overdue count for backlog guard (>= 20 -> review-only day)
    final isReviewOnly = SrsEngine.isReviewOnlyDay(reviewKeys.length);

    final newKeys = <String>[];
    if (!isReviewOnly) {
      final targetLevel = await getMeta(
        AppMetaKeys.targetStartLevel,
        fallback: 'B1',
      );
      final seenKeys = await getAllSeenWordKeys();
      final waterfall = SrsEngine.waterfallLevelsFor(targetLevel);

      for (final level in waterfall) {
        if (newKeys.length >= AppConstants.dailyNewWordsTarget) break;
        final poolKeys = await getStudyPoolKeysByLevel(level);
        final unseen = poolKeys
            .where((k) => !seenKeys.contains(k) && !newKeys.contains(k))
            .toList();
        unseen.shuffle(rng);
        final needed = AppConstants.dailyNewWordsTarget - newKeys.length;
        newKeys.addAll(unseen.take(needed));
      }
    }

    final morningKeys = <String>[...reviewKeys, ...newKeys];
    final eveningKeys = List<String>.from(newKeys)..shuffle(rng);

    final session = DailySession(
      sessionDate: today,
      newWordKeys: newKeys,
      reviewWordKeys: reviewKeys,
      morningWordKeys: morningKeys,
      eveningWordKeys: eveningKeys,
      morningErrorKeys: const [],
      morningIndex: 0,
      eveningIndex: 0,
      morningKnownCount: 0,
      eveningCorrectCount: 0,
      isReviewOnly: isReviewOnly,
      morningCompleted: morningKeys.isEmpty,
      eveningCompleted: isReviewOnly || eveningKeys.isEmpty,
    );

    await _requireUserDb.insert(
      'daily_session',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    return (await getDailySession(today)) ?? session;
  }

  /// Single atomic transaction when tapping "Sonraki" on Morning Step 3.
  Future<DailySession> recordMorningStepAtomic({
    required DailySession session,
    required String wordKey,
    required bool knewMeaning,
    required bool knewPronunciation,
    required String userSentence,
  }) async {
    final cleanSentence = TextNormalizer.sanitizeUserSentence(
      userSentence,
      maxLength: AppConstants.maxUserSentenceLength,
      maxLines: AppConstants.maxUserSentenceLines,
    );
    final isNewWord = session.newWordKeys.contains(wordKey);
    final nowIso = DateTime.now().toIso8601String();

    await _requireUserDb.transaction((txn) async {
      final existingRows = await txn.query(
        'user_progress',
        where: 'word_key = ?',
        whereArgs: [wordKey],
        limit: 1,
      );
      final existing =
          existingRows.isNotEmpty ? UserProgress.fromMap(existingRows.first) : null;

      final outcome = SrsEngine.computeMorningOutcome(
        currentScore: existing?.score ?? AppConstants.initialNewWordScore,
        isNewWord: isNewWord && existing == null,
        knewMeaning: knewMeaning,
        knewPronunciation: knewPronunciation,
        reviewCount: existing?.reviewCount ?? 0,
        lapseCount: existing?.lapseCount ?? 0,
        sessionDate: session.sessionDate,
      );

      await txn.insert(
        'user_progress',
        {
          'word_key': wordKey,
          'score': outcome.newScore,
          'next_review_date': outcome.nextReviewDate,
          'review_count': outcome.newReviewCount,
          'lapse_count': outcome.newLapseCount,
          'user_sentence': cleanSentence,
          'last_reviewed_at': nowIso,
          'created_at': existing?.createdAt ?? nowIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final updatedErrors = List<String>.from(session.morningErrorKeys);
      if (outcome.hadError && !updatedErrors.contains(wordKey)) {
        updatedErrors.add(wordKey);
      }

      final nextIndex = min(session.morningIndex + 1, session.morningWordKeys.length);
      final nextKnown = session.morningKnownCount + (knewMeaning ? 1 : 0);
      final completed = nextIndex >= session.morningWordKeys.length;

      await txn.update(
        'daily_session',
        {
          'morning_error_keys': jsonEncode(updatedErrors),
          'morning_index': nextIndex,
          'morning_known_count': nextKnown,
          'morning_completed': completed ? 1 : 0,
        },
        where: 'session_date = ?',
        whereArgs: [session.sessionDate],
      );

      if (completed) {
        await _applyStreakInsideTransaction(txn, session.sessionDate);
      }
    });

    return (await getDailySession(session.sessionDate))!;
  }

  /// Single atomic transaction when tapping "Devam Et" on an Evening Cloze question.
  Future<DailySession> recordEveningClozeStepAtomic({
    required DailySession session,
    required String wordKey,
    required bool isCorrect,
  }) async {
    final nowIso = DateTime.now().toIso8601String();
    final hadMorningError = session.morningErrorKeys.contains(wordKey);

    await _requireUserDb.transaction((txn) async {
      final existingRows = await txn.query(
        'user_progress',
        where: 'word_key = ?',
        whereArgs: [wordKey],
        limit: 1,
      );
      final existing =
          existingRows.isNotEmpty ? UserProgress.fromMap(existingRows.first) : null;

      final outcome = SrsEngine.computeEveningClozeOutcome(
        currentScore: existing?.score ?? AppConstants.initialNewWordScore,
        isCorrect: isCorrect,
        hadMorningError: hadMorningError,
        reviewCount: existing?.reviewCount ?? 0,
        lapseCount: existing?.lapseCount ?? 0,
        sessionDate: session.sessionDate,
      );

      await txn.insert(
        'user_progress',
        {
          'word_key': wordKey,
          'score': outcome.newScore,
          'next_review_date': outcome.nextReviewDate,
          'review_count': outcome.newReviewCount,
          'lapse_count': outcome.newLapseCount,
          'user_sentence': existing?.userSentence ?? '',
          'last_reviewed_at': nowIso,
          'created_at': existing?.createdAt ?? nowIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final nextIndex = min(session.eveningIndex + 1, session.eveningWordKeys.length);
      final nextCorrect = session.eveningCorrectCount + (isCorrect ? 1 : 0);
      final completed = nextIndex >= session.eveningWordKeys.length;

      await txn.update(
        'daily_session',
        {
          'evening_index': nextIndex,
          'evening_correct_count': nextCorrect,
          'evening_completed': completed ? 1 : 0,
        },
        where: 'session_date = ?',
        whereArgs: [session.sessionDate],
      );

      if (completed) {
        await _applyStreakInsideTransaction(txn, session.sessionDate);
      }
    });

    return (await getDailySession(session.sessionDate))!;
  }

  Future<void> _applyStreakInsideTransaction(
    Transaction txn,
    String sessionDate,
  ) async {
    final rows = await txn.query(
      'app_meta',
      where: 'key IN (?, ?, ?)',
      whereArgs: [
        AppMetaKeys.currentStreak,
        AppMetaKeys.longestStreak,
        AppMetaKeys.lastCompletedDate,
      ],
    );
    var cur = 0;
    var longest = 0;
    String? lastDate;
    for (final r in rows) {
      final k = r['key'] as String;
      final v = r['value'] as String;
      if (k == AppMetaKeys.currentStreak) cur = int.tryParse(v) ?? 0;
      if (k == AppMetaKeys.longestStreak) longest = int.tryParse(v) ?? 0;
      if (k == AppMetaKeys.lastCompletedDate) lastDate = v;
    }

    final update = SrsEngine.computeStreakUpdate(
      currentStreak: cur,
      longestStreak: longest,
      lastCompletedDate: lastDate,
      sessionDate: sessionDate,
    );

    if (update.didIncrement) {
      await txn.insert(
        'app_meta',
        {'key': AppMetaKeys.currentStreak, 'value': '${update.currentStreak}'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'app_meta',
        {'key': AppMetaKeys.longestStreak, 'value': '${update.longestStreak}'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'app_meta',
        {
          'key': AppMetaKeys.lastCompletedDate,
          'value': update.lastCompletedDate,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Extra practice words (never touches daily_session, streak, or next_review_date).
  Future<List<WordEntry>> getExtraPracticeWords({int count = 7}) async {
    final targetLevel = await getMeta(
      AppMetaKeys.targetStartLevel,
      fallback: 'B1',
    );
    final pool = await getStudyPoolEntries(limit: 200);
    if (pool.isEmpty) return const [];
    final preferred = pool.where((w) => w.level == targetLevel).toList();
    final rest = pool.where((w) => w.level != targetLevel).toList();
    preferred.shuffle();
    rest.shuffle();
    return [...preferred, ...rest].take(count).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // media_cache
  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>?> getMediaCacheEntry(
    String wordKey,
    String accent,
  ) async {
    final rows = await _requireUserDb.query(
      'media_cache',
      where: 'word_key = ? AND accent = ?',
      whereArgs: [wordKey, accent],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> touchMediaCache(String wordKey, String accent) async {
    await _requireUserDb.update(
      'media_cache',
      {'last_accessed_ms': DateTime.now().millisecondsSinceEpoch},
      where: 'word_key = ? AND accent = ?',
      whereArgs: [wordKey, accent],
    );
  }

  Future<void> upsertMediaCache({
    required String wordKey,
    required String accent,
    required String fileName,
    required int sizeBytes,
  }) async {
    await _requireUserDb.rawInsert(
      '''
      INSERT OR REPLACE INTO media_cache (word_key, accent, file_name, size_bytes, last_accessed_ms)
      VALUES (?, ?, ?, ?, ?)
      ''',
      [
        wordKey,
        accent,
        fileName,
        sizeBytes,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> deleteMediaCacheEntry(String wordKey, String accent) async {
    await _requireUserDb.delete(
      'media_cache',
      where: 'word_key = ? AND accent = ?',
      whereArgs: [wordKey, accent],
    );
  }

  Future<List<Map<String, Object?>>> getAllMediaCacheLru() async {
    return _requireUserDb.query(
      'media_cache',
      orderBy: 'last_accessed_ms ASC',
    );
  }

  Future<int> getTotalMediaCacheBytes() async {
    final rows = await _requireUserDb.rawQuery(
      'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM media_cache;',
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<void> clearAllMediaCacheRows() async {
    await _requireUserDb.delete('media_cache');
  }

  // ---------------------------------------------------------------------------
  // Hardened Backup Import (single SQLite transaction)
  // ---------------------------------------------------------------------------

  Future<void> applyValidatedBackupAtomic({
    required List<UserProgress> progressRows,
    required Map<String, String> meta,
  }) async {
    final today = LexoraDateUtils.todayLocalKey();
    await _requireUserDb.transaction((txn) async {
      await txn.delete('user_progress');
      // Clear today's daily_session so it regenerates cleanly from restored state.
      await txn.delete(
        'daily_session',
        where: 'session_date = ?',
        whereArgs: [today],
      );

      final batch = txn.batch();
      for (final row in progressRows) {
        batch.insert(
          'user_progress',
          row.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final entry in meta.entries) {
        batch.insert(
          'app_meta',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }
}
