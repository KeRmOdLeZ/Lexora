import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/date_utils.dart';
import '../models/word_entry.dart';
import 'audio_validator.dart';
import 'database_service.dart';

/// Playing status emitted to UI pronunciation buttons.
class AudioPlaybackState {
  const AudioPlaybackState({
    this.activeWordKey,
    this.activeAccent,
    this.isLoading = false,
    this.isPlaying = false,
  });

  final String? activeWordKey;
  final String? activeAccent;
  final bool isLoading;
  final bool isPlaying;

  bool isActiveFor(String wordKey, String accent) =>
      activeWordKey == wordKey && activeAccent == accent && (isLoading || isPlaying);
}

/// Dual-accent (US/UK) offline-first Audio & TTS engine with strict SSRF,
/// redirect, magic-byte, LRU cache, audio focus, and race-condition guards.
class AudioService {
  AudioService({
    required DatabaseService databaseService,
    this.onMissingEnglishTts,
  }) : _db = databaseService;

  final DatabaseService _db;
  VoidCallback? onMissingEnglishTts;

  final AudioPlayer _player = AudioPlayer(handleAudioSessionActivation: false);
  final FlutterTts _tts = FlutterTts();
  final Connectivity _connectivity = Connectivity();
  final Dio _dio = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (status) => status != null && status >= 200 && status < 400,
      connectTimeout: const Duration(milliseconds: 1500),
      receiveTimeout: const Duration(milliseconds: 2000),
      headers: const {
        'User-Agent': AppConstants.httpUserAgent,
      },
    ),
  );

  final StreamController<AudioPlaybackState> _stateController =
      StreamController<AudioPlaybackState>.broadcast();
  Stream<AudioPlaybackState> get playbackStateStream => _stateController.stream;

  AudioPlaybackState _currentState = const AudioPlaybackState();
  AudioPlaybackState get currentState => _currentState;

  AudioSession? _audioSession;
  Future<void>? _initFuture;
  StreamSubscription<void>? _noisySub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  int _playRequestId = 0;
  bool _notifiedMissingTts = false;

  // Session-local blacklist of unplayable local audio files (max 500 entries).
  final Set<String> _unplayableAudioKeys = <String>{};

  // Deduplicates concurrent downloads for identical (wordKey, accent).
  final Map<String, Future<File?>> _inFlightDownloads = <String, Future<File?>>{};

  // Cached offline English voices per accent ('us' / 'uk').
  Map<String, String>? _offlineUsVoice;
  Map<String, String>? _offlineUkVoice;
  bool _hasOfflineUsLanguage = false;
  bool _hasOfflineUkLanguage = false;
  bool _ttsVoicesLoaded = false;

  void _emitState(AudioPlaybackState state) {
    _currentState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// Cached initialization future preventing first-tap TTS race conditions.
  Future<void> _ensureInitialized() {
    return _initFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
      _audioSession = session;

      _noisySub = session.becomingNoisyEventStream.listen((_) {
        unawaited(stopAll());
      });
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          unawaited(stopAll());
        }
      });
    } catch (e) {
      lexoraLog('AudioSession init error: $e');
    }

    _playerStateSub = _player.playerStateStream.listen((ps) {
      if (ps.processingState == ProcessingState.completed) {
        final reqId = _playRequestId;
        _emitState(const AudioPlaybackState());
        unawaited(_deactivateSessionIfCurrent(reqId));
      }
    });

    await _initOfflineTts();
  }

  Future<void> _initOfflineTts() async {
    try {
      // Prefer Google TTS engine if installed on device.
      final enginesRaw = await _tts.getEngines;
      if (enginesRaw is List) {
        final engines = enginesRaw.map((e) => e.toString()).toList();
        if (engines.contains('com.google.android.tts')) {
          await _tts.setEngine('com.google.android.tts');
        }
      }

      await _tts.awaitSpeakCompletion(true);

      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is List && voicesRaw.isNotEmpty) {
        for (final item in voicesRaw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final name = (map['name'] ?? '').toString();
          final rawLocale = (map['locale'] ?? '').toString();
          final normLocale = rawLocale.replaceAll('_', '-').toLowerCase();
          final netRequired = map['networkConnectionRequired'] == true ||
              map['networkConnectionRequired']?.toString().toLowerCase() == 'true';

          // Strictly reject network-required voices.
          if (netRequired || name.toLowerCase().contains('network')) {
            continue;
          }

          final voiceMap = Map<String, String>.fromEntries(
            map.entries.map((e) => MapEntry(e.key, e.value?.toString() ?? '')),
          );

          if (normLocale == 'en-us' && _offlineUsVoice == null) {
            _offlineUsVoice = voiceMap;
            _hasOfflineUsLanguage = true;
          } else if (normLocale == 'en-gb' && _offlineUkVoice == null) {
            _offlineUkVoice = voiceMap;
            _hasOfflineUkLanguage = true;
          } else if (normLocale.startsWith('en-') &&
              _offlineUsVoice == null &&
              normLocale != 'en-gb') {
            _offlineUsVoice = voiceMap;
            _hasOfflineUsLanguage = true;
          }
        }
      } else {
        // Fallback check when getVoices() returns empty on some OEM ROMs.
        final usAvail = await _tts.isLanguageAvailable('en-US');
        final ukAvail = await _tts.isLanguageAvailable('en-GB');
        _hasOfflineUsLanguage = _isLanguageAvailableResult(usAvail);
        _hasOfflineUkLanguage = _isLanguageAvailableResult(ukAvail);
      }

      _ttsVoicesLoaded = true;
    } catch (e) {
      lexoraLog('Offline TTS init error: $e');
      _ttsVoicesLoaded = true;
    }
  }

  static bool _isLanguageAvailableResult(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value > 0;
    return value?.toString().toLowerCase() == 'true';
  }

  /// Handles AppLifecycleState changes (immediately halts playback & releases audio focus).
  Future<void> onAppLifecycleChanged(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      await stopAll();
      try {
        await _audioSession?.setActive(false);
      } catch (_) {}
    }
  }

  /// Stops active audio player and TTS cleanly, invalidating any in-flight play request.
  Future<void> stopAll() async {
    _playRequestId++;
    _emitState(const AudioPlaybackState());
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> _deactivateSessionIfCurrent(int requestId) async {
    if (requestId != _playRequestId) return;
    try {
      await _audioSession?.setActive(false);
    } catch (_) {}
  }

  /// Plays pronunciation for a word in the requested accent (`'us'` | `'uk'`).
  /// Offline-first: checks local cache -> if online & valid Wikimedia path, downloads ->
  /// falls back instantly to strictly offline English TTS (never Turkish).
  Future<void> playWord(WordEntry entry, {required String accent}) async {
    final normalizedAccent = accent == 'uk' ? 'uk' : 'us';
    final reqId = ++_playRequestId;

    await _ensureInitialized();
    if (reqId != _playRequestId) return;

    try {
      await _player.stop();
      await _tts.stop();
    } catch (_) {}
    if (reqId != _playRequestId) return;

    _emitState(
      AudioPlaybackState(
        activeWordKey: entry.wordKey,
        activeAccent: normalizedAccent,
        isLoading: true,
      ),
    );

    try {
      await _audioSession?.setActive(true);
    } catch (_) {}
    if (reqId != _playRequestId) return;

    final pairKey = '${entry.wordKey}|$normalizedAccent';
    final relativeAudioPath = entry.audioForAccent(normalizedAccent);

    if (!_unplayableAudioKeys.contains(pairKey) &&
        AudioValidator.isValidRelativeWikimediaPath(relativeAudioPath)) {
      // 1) Local cache lookup
      File? cachedFile = await _getValidCachedFile(entry.wordKey, normalizedAccent);
      if (reqId != _playRequestId) return;

      // 2) If not cached, check connectivity (< 50 ms) before attempting network fetch
      if (cachedFile == null) {
        final online = await _isOnline();
        if (reqId != _playRequestId) return;
        if (online) {
          cachedFile = await _downloadWithDeduplication(
            wordKey: entry.wordKey,
            accent: normalizedAccent,
            relativePath: relativeAudioPath!,
            wallClockTimeout: const Duration(milliseconds: 2500),
          );
          if (reqId != _playRequestId) return;
        }
      }

      // 3) Attempt local audio playback
      if (cachedFile != null && await cachedFile.exists()) {
        try {
          await _player.setFilePath(cachedFile.path);
          if (reqId != _playRequestId) return;
          _emitState(
            AudioPlaybackState(
              activeWordKey: entry.wordKey,
              activeAccent: normalizedAccent,
              isPlaying: true,
            ),
          );
          await _player.play();
          return;
        } on PlayerException catch (e) {
          lexoraLog('Local audio PlayerException, evicting corrupt cache: $e');
          await _handleCorruptLocalFile(
            wordKey: entry.wordKey,
            accent: normalizedAccent,
            file: cachedFile,
            pairKey: pairKey,
          );
          if (reqId != _playRequestId) return;
        } catch (e) {
          lexoraLog('Audio playback error: $e');
          if (reqId != _playRequestId) return;
        }
      }
    }

    // 4) Instant offline English TTS fallback
    await _speakOfflineEnglish(
      text: entry.wordDisplay,
      accent: normalizedAccent,
      requestId: reqId,
      wordKey: entry.wordKey,
    );
  }

  /// Background pre-caching helper (used by `audio_cache_task` with 10s wall-clock cap).
  Future<bool> preCacheWordAudio(
    WordEntry entry, {
    required String accent,
  }) async {
    final normalizedAccent = accent == 'uk' ? 'uk' : 'us';
    final rel = entry.audioForAccent(normalizedAccent);
    if (!AudioValidator.isValidRelativeWikimediaPath(rel)) return false;

    final existing = await _getValidCachedFile(entry.wordKey, normalizedAccent);
    if (existing != null) return true;

    final file = await _downloadWithDeduplication(
      wordKey: entry.wordKey,
      accent: normalizedAccent,
      relativePath: rel!,
      wallClockTimeout: const Duration(seconds: 10),
    );
    return file != null;
  }

  Future<void> _speakOfflineEnglish({
    required String text,
    required String accent,
    required int requestId,
    required String wordKey,
  }) async {
    if (requestId != _playRequestId) return;
    if (!_ttsVoicesLoaded) {
      await _initOfflineTts();
      if (requestId != _playRequestId) return;
    }

    final preferredVoice = accent == 'uk'
        ? (_offlineUkVoice ?? _offlineUsVoice)
        : (_offlineUsVoice ?? _offlineUkVoice);
    final preferredLang = accent == 'uk'
        ? (_hasOfflineUkLanguage ? 'en-GB' : (_hasOfflineUsLanguage ? 'en-US' : null))
        : (_hasOfflineUsLanguage ? 'en-US' : (_hasOfflineUkLanguage ? 'en-GB' : null));

    if (preferredVoice == null && preferredLang == null) {
      // NEVER fall back to Turkish or non-English system language!
      _emitState(const AudioPlaybackState());
      await _deactivateSessionIfCurrent(requestId);
      if (!_notifiedMissingTts) {
        _notifiedMissingTts = true;
        onMissingEnglishTts?.call();
      }
      return;
    }

    try {
      // Exact mandatory order: setLanguage -> setVoice -> setSpeechRate(0.48)
      await _tts.setLanguage(preferredLang ?? (accent == 'uk' ? 'en-GB' : 'en-US'));
      if (requestId != _playRequestId) return;
      if (preferredVoice != null) {
        await _tts.setVoice(Map<String, String>.from(preferredVoice));
        if (requestId != _playRequestId) return;
      }
      await _tts.setSpeechRate(0.48);
      if (requestId != _playRequestId) return;

      _emitState(
        AudioPlaybackState(
          activeWordKey: wordKey,
          activeAccent: accent,
          isPlaying: true,
        ),
      );
      await _tts.speak(text);
    } catch (e) {
      lexoraLog('Offline TTS speak error: $e');
    } finally {
      if (requestId == _playRequestId) {
        _emitState(const AudioPlaybackState());
        await _deactivateSessionIfCurrent(requestId);
      }
    }
  }

  Future<bool> _isOnline() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  Future<Directory> getAudioCacheDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final cacheDir = Directory(p.join(supportDir.path, 'audio_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  Future<File?> _getValidCachedFile(String wordKey, String accent) async {
    final row = await _db.getMediaCacheEntry(wordKey, accent);
    if (row == null) return null;
    final fileName = row['file_name'] as String?;
    if (fileName == null || !AudioValidator.isValidCacheFileName(fileName)) {
      await _db.deleteMediaCacheEntry(wordKey, accent);
      return null;
    }
    final dir = await getAudioCacheDir();
    final file = File(p.join(dir.path, fileName));
    if (!await file.exists()) {
      await _db.deleteMediaCacheEntry(wordKey, accent);
      return null;
    }
    await _db.touchMediaCache(wordKey, accent);
    return file;
  }

  Future<File?> _downloadWithDeduplication({
    required String wordKey,
    required String accent,
    required String relativePath,
    required Duration wallClockTimeout,
  }) {
    final dedupKey = '$wordKey|$accent';
    final existing = _inFlightDownloads[dedupKey];
    if (existing != null) return existing;

    final future = _downloadAudioStrict(
      wordKey: wordKey,
      accent: accent,
      relativePath: relativePath,
      wallClockTimeout: wallClockTimeout,
    ).whenComplete(() {
      _inFlightDownloads.remove(dedupKey);
    });

    _inFlightDownloads[dedupKey] = future;
    return future;
  }

  Future<File?> _downloadAudioStrict({
    required String wordKey,
    required String accent,
    required String relativePath,
    required Duration wallClockTimeout,
  }) async {
    final initialUri = AudioValidator.buildVerifiedWikimediaUri(relativePath);
    if (initialUri == null) return null;

    final ext = AudioValidator.extractAllowedExtension(relativePath);
    if (ext == null) return null;

    final cancelToken = CancelToken();
    final timer = Timer(wallClockTimeout, () {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('Wall-clock audio download timeout');
      }
    });

    File? tmpFile;
    try {
      // Manual redirect loop (max 2 hops, strict Wikimedia HTTPS host/port/path checks)
      var currentUri = initialUri;
      Response<ResponseBody>? response;

      for (var hop = 0; hop <= AppConstants.maxRedirectHops; hop++) {
        final res = await _dio.getUri<ResponseBody>(
          currentUri,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
          ),
        );

        final code = res.statusCode ?? 0;
        if (code >= 300 && code < 400) {
          // Drain/close redirect body stream before hopping
          unawaited(res.data?.stream.drain<void>().catchError((_) {}));
          if (hop >= AppConstants.maxRedirectHops) {
            return null;
          }
          final location = res.headers.value('location');
          final nextUri = AudioValidator.resolveAndValidateRedirect(
            currentUri,
            location,
          );
          if (nextUri == null) {
            return null;
          }
          currentUri = nextUri;
          continue;
        }

        if (code == 200 && res.data != null) {
          response = res;
          break;
        }
        return null;
      }

      if (response == null || response.data == null) return null;

      final cacheDir = await getAudioCacheDir();
      final hashName =
          '${sha256.convert(utf8.encode('$wordKey|$accent|$relativePath'))}$ext';
      if (!AudioValidator.isValidCacheFileName(hashName)) return null;

      final targetFile = File(p.join(cacheDir.path, hashName));
      final uniqueSuffix =
          '${DateTime.now().microsecondsSinceEpoch}_${wordKey.hashCode.abs()}';
      tmpFile = File(p.join(cacheDir.path, '$hashName.$uniqueSuffix.tmp'));

      final headerBuf = BytesBuilder(copy: false);
      var totalBytes = 0;
      var headerVerified = false;

      final sink = tmpFile.openWrite();
      try {
        await for (final chunk in response.data!.stream) {
          if (cancelToken.isCancelled) {
            throw DioException.requestCancelled(
              requestOptions: response.requestOptions,
              reason: 'Cancelled',
            );
          }
          totalBytes += chunk.length;
          if (totalBytes > AppConstants.maxAudioFileBytes) {
            throw const FormatException('Audio stream exceeded 2 MB limit.');
          }

          if (!headerVerified) {
            final remaining = 16 - headerBuf.length;
            if (remaining > 0) {
              headerBuf.add(
                chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
              );
            }
            if (headerBuf.length >= 16) {
              final headerBytes = headerBuf.toBytes();
              if (!AudioValidator.validateAudioMagicBytes(headerBytes, ext)) {
                throw const FormatException('Invalid audio magic bytes.');
              }
              headerVerified = true;
            }
          }

          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (totalBytes < AppConstants.minAudioFileBytes) {
        await _safeDelete(tmpFile);
        return null;
      }
      if (!headerVerified) {
        final headerBytes = headerBuf.toBytes();
        if (!AudioValidator.validateAudioMagicBytes(headerBytes, ext)) {
          await _safeDelete(tmpFile);
          return null;
        }
      }

      // Atomic rename to final cache location
      tmpFile.renameSync(targetFile.path);
      tmpFile = null;

      await _db.upsertMediaCache(
        wordKey: wordKey,
        accent: accent,
        fileName: hashName,
        sizeBytes: totalBytes,
      );
      await enforceLruCacheBudget();

      return targetFile;
    } catch (e) {
      lexoraLog('Audio download fallback to TTS ($wordKey/$accent): $e');
      if (tmpFile != null) {
        await _safeDelete(tmpFile);
      }
      return null;
    } finally {
      timer.cancel();
    }
  }

  Future<void> _handleCorruptLocalFile({
    required String wordKey,
    required String accent,
    required File file,
    required String pairKey,
  }) async {
    await _safeDelete(file);
    await _db.deleteMediaCacheEntry(wordKey, accent);
    if (_unplayableAudioKeys.length >= AppConstants.maxUnplayableAudioKeys) {
      _unplayableAudioKeys.remove(_unplayableAudioKeys.first);
    }
    _unplayableAudioKeys.add(pairKey);
  }

  /// Evicts oldest media_cache entries above 50 MB while protecting today's active session words.
  Future<void> enforceLruCacheBudget() async {
    var totalBytes = await _db.getTotalMediaCacheBytes();
    if (totalBytes <= AppConstants.maxAudioCacheBytes) return;

    final today = LexoraDateUtils.todayLocalKey();
    final todaySession = await _db.getDailySession(today);
    final protectedKeys = <String>{
      ...?todaySession?.newWordKeys,
      ...?todaySession?.reviewWordKeys,
    };

    final rows = await _db.getAllMediaCacheLru();
    final cacheDir = await getAudioCacheDir();

    for (final row in rows) {
      if (totalBytes <= AppConstants.maxAudioCacheBytes) break;
      final wk = row['word_key'] as String;
      final accent = row['accent'] as String;
      final fileName = row['file_name'] as String;
      final sizeBytes = (row['size_bytes'] as int?) ?? 0;

      if (protectedKeys.contains(wk)) continue;

      if (AudioValidator.isValidCacheFileName(fileName)) {
        await _safeDelete(File(p.join(cacheDir.path, fileName)));
      }
      await _db.deleteMediaCacheEntry(wk, accent);
      totalBytes -= sizeBytes;
    }
  }

  /// Clears all cached audio files and `media_cache` metadata (called from Settings).
  Future<void> clearAllAudioCache() async {
    await stopAll();
    final dir = await getAudioCacheDir();
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        try {
          if (entity is File) {
            await entity.delete();
          }
        } catch (_) {}
      }
    }
    await _db.clearAllMediaCacheRows();
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stopAll();
    await _noisySub?.cancel();
    await _interruptionSub?.cancel();
    await _playerStateSub?.cancel();
    await _player.dispose();
    await _stateController.close();
  }
}
