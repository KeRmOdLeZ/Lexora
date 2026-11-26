import 'dart:convert';

/// Compact sense group stored inside `words.senses` (`[{"p":"verb","d":["..."]}]`).
class SenseGroup {
  const SenseGroup({
    required this.pos,
    required this.definitions,
  });

  final String pos;
  final List<String> definitions;

  factory SenseGroup.fromJson(Map<String, dynamic> json) {
    final pos = (json['p'] ?? '').toString();
    final rawDefs = json['d'];
    final defs = rawDefs is List
        ? rawDefs.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return SenseGroup(pos: pos, definitions: defs);
  }
}

/// Read-only dictionary row from `vocab_dict.db` -> `words`.
class WordEntry {
  const WordEntry({
    required this.wordKey,
    required this.wordDisplay,
    required this.level,
    required this.primaryPos,
    required this.meaningEn,
    required this.senses,
    required this.examples,
    required this.clozeExample,
    required this.synonyms,
    required this.ipaUs,
    required this.ipaUk,
    required this.audioUs,
    required this.audioUk,
  });

  final String wordKey;
  final String wordDisplay;
  final String? level;
  final String primaryPos;
  final String meaningEn;
  final List<SenseGroup> senses;
  final List<String> examples;
  final String? clozeExample;
  final List<String> synonyms;
  final String? ipaUs;
  final String? ipaUk;
  final String? audioUs;
  final String? audioUk;

  int get wordCount {
    final parts = wordKey.trim().split(RegExp(r'\s+'));
    return parts.where((p) => p.isNotEmpty).length;
  }

  String? ipaForAccent(String accent) {
    if (accent == 'uk') return ipaUk ?? ipaUs;
    return ipaUs ?? ipaUk;
  }

  String? audioForAccent(String accent) {
    return accent == 'uk' ? audioUk : audioUs;
  }

  factory WordEntry.fromMap(Map<String, Object?> map) {
    return WordEntry(
      wordKey: map['word_key'] as String,
      wordDisplay: map['word_display'] as String,
      level: map['level'] as String?,
      primaryPos: map['primary_pos'] as String,
      meaningEn: map['meaning_en'] as String,
      senses: _parseSenses(map['senses'] as String?),
      examples: _parseStringList(map['examples'] as String?),
      clozeExample: map['cloze_example'] as String?,
      synonyms: _parseStringList(map['synonyms'] as String?),
      ipaUs: map['ipa_us'] as String?,
      ipaUk: map['ipa_uk'] as String?,
      audioUs: map['audio_us'] as String?,
      audioUk: map['audio_uk'] as String?,
    );
  }

  static List<SenseGroup> _parseSenses(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => SenseGroup.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static List<String> _parseStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

/// Dictionary search hit with optional inflected form label (`compared → compare`).
class SearchResultItem {
  const SearchResultItem({
    required this.entry,
    this.matchedForm,
  });

  final WordEntry entry;
  final String? matchedForm;
}

/// Mastery bucket categories displayed on Dashboard and Vocab Notebook.
enum MasteryBucket {
  all,
  learning,      // score < 50
  consolidating, // 50..84
  mastered,      // >= 85
}

/// Sorting modes for Kelime Defterim (Vocab Notebook).
enum VocabSortOrder {
  nextReviewAsc,
  scoreAsc,
  scoreDesc,
  alphaAsc,
  recentDesc,
}

/// User SRS progress row from `user_data.db` -> `user_progress`.
class UserProgress {
  const UserProgress({
    required this.wordKey,
    required this.score,
    required this.nextReviewDate,
    required this.reviewCount,
    required this.lapseCount,
    required this.userSentence,
    required this.lastReviewedAt,
    required this.createdAt,
  });

  final String wordKey;
  final int score;
  final String nextReviewDate;
  final int reviewCount;
  final int lapseCount;
  final String userSentence;
  final String? lastReviewedAt;
  final String createdAt;

  MasteryBucket get bucket {
    if (score >= 85) return MasteryBucket.mastered;
    if (score >= 50) return MasteryBucket.consolidating;
    return MasteryBucket.learning;
  }

  factory UserProgress.fromMap(Map<String, Object?> map) {
    return UserProgress(
      wordKey: map['word_key'] as String,
      score: map['score'] as int,
      nextReviewDate: map['next_review_date'] as String,
      reviewCount: map['review_count'] as int,
      lapseCount: map['lapse_count'] as int,
      userSentence: (map['user_sentence'] as String?) ?? '',
      lastReviewedAt: map['last_reviewed_at'] as String?,
      createdAt: map['created_at'] as String,
    );
  }

  Map<String, Object?> toMap() => {
        'word_key': wordKey,
        'score': score,
        'next_review_date': nextReviewDate,
        'review_count': reviewCount,
        'lapse_count': lapseCount,
        'user_sentence': userSentence,
        'last_reviewed_at': lastReviewedAt,
        'created_at': createdAt,
      };
}

/// Combined notebook entry pairing user progress with dictionary metadata.
class VocabNotebookItem {
  const VocabNotebookItem({
    required this.progress,
    required this.word,
  });

  final UserProgress progress;
  final WordEntry word;
}

/// Frozen daily session row from `user_data.db` -> `daily_session`.
class DailySession {
  const DailySession({
    required this.sessionDate,
    required this.newWordKeys,
    required this.reviewWordKeys,
    required this.morningWordKeys,
    required this.eveningWordKeys,
    required this.morningErrorKeys,
    required this.morningIndex,
    required this.eveningIndex,
    required this.morningKnownCount,
    required this.eveningCorrectCount,
    required this.isReviewOnly,
    required this.morningCompleted,
    required this.eveningCompleted,
  });

  final String sessionDate;
  final List<String> newWordKeys;
  final List<String> reviewWordKeys;
  final List<String> morningWordKeys;
  final List<String> eveningWordKeys;
  final List<String> morningErrorKeys;
  final int morningIndex;
  final int eveningIndex;
  final int morningKnownCount;
  final int eveningCorrectCount;
  final bool isReviewOnly;
  final bool morningCompleted;
  final bool eveningCompleted;

  bool get hasMorningWork => morningWordKeys.isNotEmpty;
  bool get hasEveningWork => !isReviewOnly && eveningWordKeys.isNotEmpty;

  factory DailySession.fromMap(Map<String, Object?> map) {
    return DailySession(
      sessionDate: map['session_date'] as String,
      newWordKeys: _decodeStringArray(map['new_word_keys'] as String?),
      reviewWordKeys: _decodeStringArray(map['review_word_keys'] as String?),
      morningWordKeys: _decodeStringArray(map['morning_word_keys'] as String?),
      eveningWordKeys: _decodeStringArray(map['evening_word_keys'] as String?),
      morningErrorKeys: _decodeStringArray(map['morning_error_keys'] as String?),
      morningIndex: map['morning_index'] as int,
      eveningIndex: map['evening_index'] as int,
      morningKnownCount: map['morning_known_count'] as int,
      eveningCorrectCount: map['evening_correct_count'] as int,
      isReviewOnly: (map['is_review_only'] as int) != 0,
      morningCompleted: (map['morning_completed'] as int) != 0,
      eveningCompleted: (map['evening_completed'] as int) != 0,
    );
  }

  Map<String, Object?> toMap() => {
        'session_date': sessionDate,
        'new_word_keys': jsonEncode(newWordKeys),
        'review_word_keys': jsonEncode(reviewWordKeys),
        'morning_word_keys': jsonEncode(morningWordKeys),
        'evening_word_keys': jsonEncode(eveningWordKeys),
        'morning_error_keys': jsonEncode(morningErrorKeys),
        'morning_index': morningIndex,
        'evening_index': eveningIndex,
        'morning_known_count': morningKnownCount,
        'evening_correct_count': eveningCorrectCount,
        'is_review_only': isReviewOnly ? 1 : 0,
        'morning_completed': morningCompleted ? 1 : 0,
        'evening_completed': eveningCompleted ? 1 : 0,
      };

  static List<String> _decodeStringArray(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map((e) => e.toString()).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

/// Metadata parsed from `assets/vocab_dict.meta.json`.
class DictMetadata {
  const DictMetadata({
    required this.schemaVersion,
    required this.uncompressedSha256,
    required this.uncompressedSize,
    required this.compressedSize,
    required this.wordCount,
    required this.isSample,
    required this.generatedAt,
  });

  final int schemaVersion;
  final String uncompressedSha256;
  final int uncompressedSize;
  final int compressedSize;
  final int wordCount;
  final bool isSample;
  final String generatedAt;

  factory DictMetadata.fromJson(Map<String, dynamic> json) {
    return DictMetadata(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 2,
      uncompressedSha256: (json['uncompressed_sha256'] as String?) ?? '',
      uncompressedSize: (json['uncompressed_size'] as num?)?.toInt() ?? 0,
      compressedSize: (json['compressed_size'] as num?)?.toInt() ?? 0,
      wordCount: (json['word_count'] as num?)?.toInt() ?? 0,
      isSample: (json['is_sample'] as bool?) ?? false,
      generatedAt: (json['generated_at'] as String?) ?? '',
    );
  }
}

/// Summary mastery bucket counts for Dashboard.
class MasteryCounts {
  const MasteryCounts({
    required this.learning,
    required this.consolidating,
    required this.mastered,
  });

  final int learning;
  final int consolidating;
  final int mastered;

  int get total => learning + consolidating + mastered;
}
