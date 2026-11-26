import 'dart:typed_data';

import '../core/constants.dart';

/// Strict security validation for Wikimedia Commons audio paths, redirect URIs,
/// local cache filenames, and 16-byte magic headers.
abstract final class AudioValidator {
  static final RegExp _relativePathRegex = RegExp(r'^[a-zA-Z0-9/_\.\-\(\)%]+$');
  static final RegExp _forbiddenEncodedRegex = RegExp(
    r'(%2e|%2f|%5c|%00|%0a|%0d)',
    caseSensitive: false,
  );
  static final RegExp _cacheFileNameRegex = RegExp(
    r'^[0-9a-f]{64}\.(ogg|oga|mp3)$',
  );

  static const Set<String> allowedExtensions = {'.ogg', '.oga', '.mp3'};

  /// Validates a relative Wikimedia Commons audio path stored in `vocab_dict.db`.
  static bool isValidRelativeWikimediaPath(String? rawPath) {
    if (rawPath == null || rawPath.isEmpty || rawPath.length > 512) {
      return false;
    }
    if (rawPath.startsWith('/') || rawPath.contains('..') || rawPath.contains(r'\')) {
      return false;
    }
    if (!_relativePathRegex.hasMatch(rawPath)) {
      return false;
    }
    if (_forbiddenEncodedRegex.hasMatch(rawPath)) {
      return false;
    }

    final lower = rawPath.toLowerCase();
    final hasAllowedExt = allowedExtensions.any(lower.endsWith);
    if (!hasAllowedExt) {
      return false;
    }

    try {
      final decoded = Uri.decodeFull(rawPath);
      if (decoded.startsWith('/') ||
          decoded.contains('..') ||
          decoded.contains(r'\') ||
          decoded.contains('\x00') ||
          decoded.contains('\n') ||
          decoded.contains('\r')) {
        return false;
      }
    } catch (_) {
      return false;
    }

    return true;
  }

  /// Builds a verified HTTPS Wikimedia Commons URI from a relative path, or `null` if rejected.
  static Uri? buildVerifiedWikimediaUri(String? relativePath) {
    if (!isValidRelativeWikimediaPath(relativePath)) {
      return null;
    }
    final uri = Uri.tryParse('${AppConstants.wikimediaCommonsBase}$relativePath');
    if (uri == null || !isValidWikimediaUri(uri)) {
      return null;
    }
    return uri;
  }

  /// Validates any initial or redirected download URI.
  /// Enforces: `https`, `upload.wikimedia.org`, port 443, empty `userInfo`,
  /// `/wikipedia/commons/` prefix, no query, no fragment, no traversal (`..`),
  /// and valid audio extension.
  static bool isValidWikimediaUri(Uri uri) {
    if (uri.scheme != 'https') return false;
    if (uri.host != 'upload.wikimedia.org') return false;
    if (uri.port != 443) return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.hasQuery || uri.hasFragment) return false;
    if (!uri.path.startsWith('/wikipedia/commons/')) return false;
    if (uri.path.contains('..') || uri.path.contains(r'\')) return false;
    if (_forbiddenEncodedRegex.hasMatch(uri.path)) return false;

    final lowerPath = uri.path.toLowerCase();
    if (!allowedExtensions.any(lowerPath.endsWith)) {
      return false;
    }

    try {
      final decodedPath = Uri.decodeFull(uri.path);
      if (!decodedPath.startsWith('/wikipedia/commons/') ||
          decodedPath.contains('..') ||
          decodedPath.contains(r'\') ||
          decodedPath.contains('\x00') ||
          decodedPath.contains('\n') ||
          decodedPath.contains('\r')) {
        return false;
      }
    } catch (_) {
      return false;
    }

    return true;
  }

  /// Resolves a redirect `Location` header against `currentUri` and validates it.
  static Uri? resolveAndValidateRedirect(Uri currentUri, String? location) {
    if (location == null || location.trim().isEmpty) return null;
    final trimmed = location.trim();
    if (trimmed.contains('\n') ||
        trimmed.contains('\r') ||
        trimmed.contains('\x00') ||
        trimmed.contains('..') ||
        trimmed.contains(r'\') ||
        _forbiddenEncodedRegex.hasMatch(trimmed)) {
      return null;
    }
    try {
      final resolved = currentUri.resolve(trimmed);
      return isValidWikimediaUri(resolved) ? resolved : null;
    } catch (_) {
      return null;
    }
  }

  /// Extracts lowercase extension (`.ogg`, `.oga`, `.mp3`) or returns `null`.
  static String? extractAllowedExtension(String pathOrUrl) {
    final lower = pathOrUrl.toLowerCase();
    for (final ext in allowedExtensions) {
      if (lower.endsWith(ext)) return ext;
    }
    return null;
  }

  /// Validates extension-specific magic bytes using the first 16 buffered bytes.
  /// - `.ogg` / `.oga`: `OggS` (`4F 67 67 53`)
  /// - `.mp3`: `ID3` (`49 44 33`) or valid MPEG frame sync (`FF` + valid version/layer bits)
  static bool validateAudioMagicBytes(Uint8List headerBytes, String extension) {
    if (headerBytes.length < 4) return false;
    final ext = extension.toLowerCase();

    if (ext == '.ogg' || ext == '.oga') {
      return headerBytes[0] == 0x4F && // 'O'
          headerBytes[1] == 0x67 && // 'g'
          headerBytes[2] == 0x67 && // 'g'
          headerBytes[3] == 0x53; // 'S'
    }

    if (ext == '.mp3') {
      // ID3v2 container tag
      if (headerBytes[0] == 0x49 && // 'I'
          headerBytes[1] == 0x44 && // 'D'
          headerBytes[2] == 0x33) {
        return true;
      }
      // Raw MPEG frame header sync:
      // byte0 == 0xFF
      // byte1 top 3 bits == 111 (0xE0)
      // MPEG version bits (byte1 & 0x18) != 0x08 (reserved)
      // Layer bits (byte1 & 0x06) != 0x00 (reserved)
      // Bitrate index (byte2 & 0xF0) != 0xF0 (bad)
      // Sample rate index (byte2 & 0x0C) != 0x0C (reserved)
      final b0 = headerBytes[0];
      final b1 = headerBytes[1];
      final b2 = headerBytes[2];
      return b0 == 0xFF &&
          (b1 & 0xE0) == 0xE0 &&
          (b1 & 0x18) != 0x08 &&
          (b1 & 0x06) != 0x00 &&
          (b2 & 0xF0) != 0xF0 &&
          (b2 & 0x0C) != 0x0C;
    }

    return false;
  }

  /// Validates cached local relative filename format (`^[0-9a-f]{64}\.(ogg|oga|mp3)$`).
  static bool isValidCacheFileName(String fileName) {
    return _cacheFileNameRegex.hasMatch(fileName);
  }
}
