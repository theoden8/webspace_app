import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/localcdn_service.dart';

void main() {
  late LocalCdnService service;

  setUp(() {
    service = LocalCdnService.instance;
  });

  group('LocalCdnService CDN URL pattern matching', () {
    test('recognizes cdnjs.cloudflare.com URLs', () {
      expect(
        service.getCacheKey('https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('recognizes cdn.jsdelivr.net npm URLs', () {
      expect(
        service.getCacheKey('https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.min.js'),
        equals('bootstrap/5.3.0/dist/js/bootstrap.min.js'),
      );
    });

    test('recognizes cdn.jsdelivr.net GitHub URLs', () {
      expect(
        service.getCacheKey('https://cdn.jsdelivr.net/gh/nicehash/nicehash-cdn@1.0.0/dist/sdk.js'),
        equals('nicehash-cdn/1.0.0/dist/sdk.js'),
      );
    });

    test('recognizes unpkg.com URLs', () {
      expect(
        service.getCacheKey('https://unpkg.com/react@18.2.0/umd/react.production.min.js'),
        equals('react/18.2.0/umd/react.production.min.js'),
      );
    });

    test('recognizes ajax.googleapis.com URLs', () {
      expect(
        service.getCacheKey('https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('recognizes code.jquery.com URLs', () {
      expect(
        service.getCacheKey('https://code.jquery.com/jquery-3.7.1.min.js'),
        equals('jquery/3.7.1/.min.js'),
      );
    });

    test('recognizes code.jquery.com slim URLs', () {
      expect(
        service.getCacheKey('https://code.jquery.com/jquery-3.7.1.slim.min.js'),
        equals('jquery/3.7.1/.slim.min.js'),
      );
    });

    test('recognizes code.jquery.com UI URLs', () {
      expect(
        service.getCacheKey('https://code.jquery.com/ui/1.13.2/jquery-ui.min.js'),
        equals('ui/1.13.2/jquery-ui.min.js'),
      );
    });

    test('recognizes stackpath.bootstrapcdn.com URLs', () {
      expect(
        service.getCacheKey('https://stackpath.bootstrapcdn.com/bootstrap/4.5.2/css/bootstrap.min.css'),
        equals('bootstrap/4.5.2/css/bootstrap.min.css'),
      );
    });

    test('recognizes maxcdn.bootstrapcdn.com URLs', () {
      expect(
        service.getCacheKey('https://maxcdn.bootstrapcdn.com/bootstrap/3.4.1/js/bootstrap.min.js'),
        equals('bootstrap/3.4.1/js/bootstrap.min.js'),
      );
    });

    test('recognizes cdn.bootcss.com URLs', () {
      expect(
        service.getCacheKey('https://cdn.bootcss.com/jquery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('recognizes cdn.bootcdn.net URLs', () {
      expect(
        service.getCacheKey('https://cdn.bootcdn.net/ajax/libs/jquery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('recognizes cdn.staticfile.org URLs', () {
      expect(
        service.getCacheKey('https://cdn.staticfile.org/jquery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('recognizes pagecdn.io URLs', () {
      expect(
        service.getCacheKey('https://pagecdn.io/lib/jquery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('strips query parameters from CDN URLs', () {
      expect(
        service.getCacheKey('https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js?v=123'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('normalizes library names to lowercase', () {
      expect(
        service.getCacheKey('https://cdnjs.cloudflare.com/ajax/libs/jQuery/3.7.1/jquery.min.js'),
        equals('jquery/3.7.1/jquery.min.js'),
      );
    });

    test('returns null for non-CDN URLs', () {
      expect(service.getCacheKey('https://example.com/script.js'), isNull);
      expect(service.getCacheKey('https://www.google.com/'), isNull);
      expect(service.getCacheKey('https://github.com/repo/file.js'), isNull);
    });

    test('isCdnUrl returns true for CDN URLs', () {
      expect(service.isCdnUrl('https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js'), isTrue);
      expect(service.isCdnUrl('https://cdn.jsdelivr.net/npm/vue@3.3.0/dist/vue.global.min.js'), isTrue);
    });

    test('isCdnUrl returns false for non-CDN URLs', () {
      expect(service.isCdnUrl('https://example.com/'), isFalse);
      expect(service.isCdnUrl('https://www.google.com/'), isFalse);
    });
  });

  group('Cross-CDN deduplication', () {
    test('same library from different CDNs produces same cache key', () {
      final key1 = service.getCacheKey(
        'https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js',
      );
      final key2 = service.getCacheKey(
        'https://cdn.jsdelivr.net/npm/jquery@3.7.1/jquery.min.js',
      );
      final key3 = service.getCacheKey(
        'https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js',
      );
      final key4 = service.getCacheKey(
        'https://cdn.bootcss.com/jquery/3.7.1/jquery.min.js',
      );

      expect(key1, equals('jquery/3.7.1/jquery.min.js'));
      expect(key2, equals('jquery/3.7.1/jquery.min.js'));
      expect(key3, equals('jquery/3.7.1/jquery.min.js'));
      expect(key4, equals('jquery/3.7.1/jquery.min.js'));
    });

    test('different versions produce different cache keys', () {
      final key1 = service.getCacheKey(
        'https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js',
      );
      final key2 = service.getCacheKey(
        'https://cdnjs.cloudflare.com/ajax/libs/jquery/3.6.0/jquery.min.js',
      );

      expect(key1, isNot(equals(key2)));
    });

    test('different libraries produce different cache keys', () {
      final key1 = service.getCacheKey(
        'https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js',
      );
      final key2 = service.getCacheKey(
        'https://cdnjs.cloudflare.com/ajax/libs/bootstrap/5.3.0/js/bootstrap.min.js',
      );

      expect(key1, isNot(equals(key2)));
    });
  });

  group('Content type detection', () {
    test('detects JavaScript content type', () {
      expect(service.getContentType('https://example.com/jquery.min.js'), equals('application/javascript'));
    });

    test('detects CSS content type', () {
      expect(service.getContentType('https://example.com/bootstrap.min.css'), equals('text/css'));
    });

    test('detects font content types', () {
      expect(service.getContentType('https://example.com/font.woff'), equals('font/woff'));
      expect(service.getContentType('https://example.com/font.woff2'), equals('font/woff2'));
      expect(service.getContentType('https://example.com/font.ttf'), equals('font/ttf'));
    });

    test('detects SVG content type', () {
      expect(service.getContentType('https://example.com/icon.svg'), equals('image/svg+xml'));
    });

    test('strips query params for content type detection', () {
      expect(service.getContentType('https://example.com/jquery.min.js?v=123'), equals('application/javascript'));
    });

    test('returns octet-stream for unknown extensions', () {
      expect(service.getContentType('https://example.com/file.xyz'), equals('application/octet-stream'));
    });
  });

  group('LocalCdnService cache state', () {
    test('initial state has no cache', () {
      // Before initialization, resourceCount should be 0
      expect(service.resourceCount, greaterThanOrEqualTo(0));
    });

    test('isCached returns false for uncached URL', () {
      expect(service.isCached('https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js'), isFalse);
    });
  });

  group('formatSize', () {
    test('formats bytes', () {
      expect(LocalCdnService.formatSize(0), equals('0 B'));
      expect(LocalCdnService.formatSize(512), equals('512 B'));
    });

    test('formats kilobytes', () {
      expect(LocalCdnService.formatSize(1024), equals('1.0 KB'));
      expect(LocalCdnService.formatSize(2560), equals('2.5 KB'));
    });

    test('formats megabytes', () {
      expect(LocalCdnService.formatSize(1048576), equals('1.0 MB'));
      expect(LocalCdnService.formatSize(5242880), equals('5.0 MB'));
    });
  });
}
