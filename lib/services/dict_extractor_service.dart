import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../models/word_entry.dart';

/// Bridge to the native Kotlin `DictExtractor` singleton.
class DictExtractorService {
  static const MethodChannel _methodChannel = MethodChannel(
    AppConstants.dictExtractorMethodChannel,
  );
  static const EventChannel _progressChannel = EventChannel(
    AppConstants.dictExtractorProgressChannel,
  );

  DictMetadata? _cachedMeta;

  /// Reads bundled `assets/vocab_dict.meta.json`.
  Future<DictMetadata> loadAssetMetadata() async {
    if (_cachedMeta != null) return _cachedMeta!;
    final raw = await rootBundle.loadString('assets/vocab_dict.meta.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    _cachedMeta = DictMetadata.fromJson(decoded);
    return _cachedMeta!;
  }

  /// Streams decompression progress values (`0.0` .. `1.0`) from Kotlin.
  Stream<double> get progressStream {
    return _progressChannel.receiveBroadcastStream().map((event) {
      if (event is num) {
        return event.toDouble().clamp(0.0, 1.0);
      }
      return 0.0;
    });
  }

  /// Triggers native atomic gzip extraction + SHA-256 verification into `vocab_dict.db`.
  /// Concurrent calls safely join the active extraction in Kotlin without failing.
  Future<String> extractDict() async {
    final path = await _methodChannel.invokeMethod<String>('extractDict');
    if (path == null || path.isEmpty) {
      throw PlatformException(
        code: 'EMPTY_PATH',
        message: 'Native DictExtractor returned an empty database path.',
      );
    }
    return path;
  }

  /// Returns canonical Android database path for `vocab_dict.db`.
  Future<String> getDictDbPath() async {
    final path = await _methodChannel.invokeMethod<String>('getDictDbPath');
    if (path == null || path.isEmpty) {
      throw PlatformException(
        code: 'EMPTY_PATH',
        message: 'Native getDictDbPath returned empty.',
      );
    }
    return path;
  }

  /// Opens Android Text-to-Speech settings safely (falls back to system settings).
  Future<void> openTtsSettings() async {
    try {
      await _methodChannel.invokeMethod<void>('openTtsSettings');
    } catch (e) {
      lexoraLog('openTtsSettings error: $e');
    }
  }
}
