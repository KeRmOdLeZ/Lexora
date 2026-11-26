import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexora/services/audio_validator.dart';

void main() {
  group('AudioValidator Wikimedia path & URI security', () {
    test('accepts clean relative Wikimedia Commons audio paths', () {
      expect(
        AudioValidator.isValidRelativeWikimediaPath('3/3c/En-us-schedule.ogg'),
        isTrue,
      );
      expect(
        AudioValidator.isValidRelativeWikimediaPath(
          'transcoded/a/a8/En-us-vitamin.ogg/En-us-vitamin.ogg.mp3',
        ),
        isTrue,
      );
      expect(
        AudioValidator.buildVerifiedWikimediaUri('3/3c/En-us-schedule.ogg'),
        Uri.parse(
          'https://upload.wikimedia.org/wikipedia/commons/3/3c/En-us-schedule.ogg',
        ),
      );
    });

    test('rejects %2e%2e, %2f, %5c, control encodings, traversal, and bad extensions', () {
      const maliciousPaths = [
        '3/3c/%2e%2e/secret.ogg',
        '3/3c/%2E%2E/secret.ogg',
        '3/3c/%2fetc/passwd.ogg',
        '3/3c/%5cwindows.ogg',
        '3/3c/file%00.ogg',
        '3/3c/file%0a.ogg',
        '3/3c/file%0d.ogg',
        '../escape.ogg',
        '/absolute/path.ogg',
        '3/3c/script.html',
        '3/3c/audio.ogg?download=1',
        '3/3c/audio.ogg#frag',
      ];
      for (final path in maliciousPaths) {
        expect(
          AudioValidator.isValidRelativeWikimediaPath(path),
          isFalse,
          reason: 'Should reject malicious path: $path',
        );
      }
    });

    test('rejects userInfo, HTTP downgrade, foreign host, non-443 port, query, fragment', () {
      final badUris = [
        Uri.parse('https://user:pass@upload.wikimedia.org/wikipedia/commons/a.ogg'),
        Uri.parse('https://evil.com@upload.wikimedia.org/wikipedia/commons/a.ogg'),
        Uri.parse('http://upload.wikimedia.org/wikipedia/commons/a.ogg'),
        Uri.parse('https://upload.wikimedia.org:8443/wikipedia/commons/a.ogg'),
        Uri.parse('https://attacker.example/wikipedia/commons/a.ogg'),
        Uri.parse('https://upload.wikimedia.org/wikipedia/commons/a.ogg?x=1'),
        Uri.parse('https://upload.wikimedia.org/wikipedia/commons/a.ogg#top'),
        Uri.parse('https://upload.wikimedia.org/wikipedia/%2e%2e/a.ogg'),
      ];
      for (final uri in badUris) {
        expect(
          AudioValidator.isValidWikimediaUri(uri),
          isFalse,
          reason: 'Should reject unsafe URI: $uri',
        );
      }
    });

    test('validates manual redirects strictly against Wikimedia HTTPS allowlist', () {
      final base = Uri.parse(
        'https://upload.wikimedia.org/wikipedia/commons/3/3c/En-us-schedule.ogg',
      );
      expect(
        AudioValidator.resolveAndValidateRedirect(
          base,
          '/wikipedia/commons/9/9a/En-uk-schedule.ogg',
        ),
        Uri.parse(
          'https://upload.wikimedia.org/wikipedia/commons/9/9a/En-uk-schedule.ogg',
        ),
      );
      expect(
        AudioValidator.resolveAndValidateRedirect(
          base,
          'http://upload.wikimedia.org/wikipedia/commons/9/9a/En-uk-schedule.ogg',
        ),
        isNull,
      );
      expect(
        AudioValidator.resolveAndValidateRedirect(
          base,
          'https://evil.org/payload.ogg',
        ),
        isNull,
      );
      expect(
        AudioValidator.resolveAndValidateRedirect(
          base,
          'https://user@upload.wikimedia.org/wikipedia/commons/a.ogg',
        ),
        isNull,
      );
    });
  });

  group('AudioValidator 16-byte magic headers & cache filename', () {
    test('verifies OggS magic bytes for .ogg/.oga and rejects spoofed headers', () {
      final validOgg = Uint8List.fromList([
        0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34,
      ]);
      final htmlFake = Uint8List.fromList('<!DOCTYPE html>!'.codeUnits);

      expect(AudioValidator.validateAudioMagicBytes(validOgg, '.ogg'), isTrue);
      expect(AudioValidator.validateAudioMagicBytes(validOgg, '.oga'), isTrue);
      expect(AudioValidator.validateAudioMagicBytes(validOgg, '.mp3'), isFalse);
      expect(AudioValidator.validateAudioMagicBytes(htmlFake, '.ogg'), isFalse);
    });

    test('verifies ID3 and MPEG frame sync headers for .mp3', () {
      final id3Mp3 = Uint8List.fromList([
        0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
      final rawMpegSync = Uint8List.fromList([
        0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
      final invalidSync = Uint8List.fromList([
        0xFF, 0xE8, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);

      expect(AudioValidator.validateAudioMagicBytes(id3Mp3, '.mp3'), isTrue);
      expect(AudioValidator.validateAudioMagicBytes(rawMpegSync, '.mp3'), isTrue);
      expect(AudioValidator.validateAudioMagicBytes(invalidSync, '.mp3'), isFalse);
      expect(AudioValidator.validateAudioMagicBytes(Uint8List(3), '.mp3'), isFalse);
    });

    test('validates 64-hex local cache file names strictly', () {
      final valid = '${'a' * 64}.ogg';
      expect(AudioValidator.isValidCacheFileName(valid), isTrue);
      expect(AudioValidator.isValidCacheFileName('../${'a' * 64}.ogg'), isFalse);
      expect(AudioValidator.isValidCacheFileName('${'a' * 63}.ogg'), isFalse);
      expect(AudioValidator.isValidCacheFileName('${'a' * 64}.wav'), isFalse);
    });
  });
}
