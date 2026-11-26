import 'package:flutter_test/flutter_test.dart';
import 'package:lexora/services/app_bootstrap.dart';
import 'package:lexora/services/database_service.dart';

void main() {
  group('DatabaseService.chunkList SQLite variable safety', () {
    test('chunks large lists into <= 500 element batches without losing items', () {
      final keys = List.generate(1234, (i) => 'word_$i');
      final chunks = DatabaseService.chunkList(keys);
      expect(chunks.length, 3);
      expect(chunks[0].length, 500);
      expect(chunks[1].length, 500);
      expect(chunks[2].length, 234);
      expect(chunks.expand((c) => c).toList(), keys);
    });
  });

  group('AppBootstrap.parseWordDeepLink', () {
    test('decodes valid lexora://word/<encodedKey> links and rejects others', () {
      expect(
        AppBootstrap.parseWordDeepLink(Uri.parse('lexora://word/carry%20out')),
        'carry out',
      );
      expect(
        AppBootstrap.parseWordDeepLink(Uri.parse('lexora://word/na%C3%AFve')),
        'naïve',
      );
      expect(
        AppBootstrap.parseWordDeepLink(Uri.parse('lexora://refresh')),
        isNull,
      );
      expect(
        AppBootstrap.parseWordDeepLink(Uri.parse('https://evil.com/word/test')),
        isNull,
      );
    });
  });
}
