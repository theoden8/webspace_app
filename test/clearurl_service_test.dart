import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/clearurl_service.dart';

void main() {
  group('ClearUrlService', () {
    late ClearUrlService service;

    setUp(() {
      service = ClearUrlService.instance;
    });

    test('cleanUrl returns original URL when no rules loaded', () {
      // Fresh instance with no rules
      final freshService = ClearUrlService.instance;
      // Without loading any rules, hasRules should reflect current state
      final url = 'https://example.com?utm_source=test';
      // cleanUrl returns original when no providers match
      expect(freshService.cleanUrl(url), equals(url));
    });

    group('with rules loaded', () {
      setUp(() {
        service.loadRulesFromJson({
          'providers': {
            'google': {
              'urlPattern': r'google\.com',
              'completeProvider': false,
              'rules': [
                r'^utm_source$',
                r'^utm_medium$',
                r'^utm_campaign$',
                r'^utm_content$',
                r'^utm_term$',
                r'^fbclid$',
              ],
              'rawRules': [],
              'exceptions': [],
              'redirections': [],
            },
          },
        });
      });

      test('strips utm_source parameter', () {
        final result = service.cleanUrl(
          'https://www.google.com/search?q=test&utm_source=newsletter',
        );
        expect(result, equals('https://www.google.com/search?q=test'));
      });

      test('strips multiple tracking parameters', () {
        final result = service.cleanUrl(
          'https://www.google.com/search?q=test&utm_source=newsletter&utm_medium=email&utm_campaign=summer',
        );
        expect(result, equals('https://www.google.com/search?q=test'));
      });

      test('strips fbclid parameter', () {
        final result = service.cleanUrl(
          'https://www.google.com/page?id=123&fbclid=abc123def',
        );
        expect(result, equals('https://www.google.com/page?id=123'));
      });

      test('preserves URL when no tracking params present', () {
        final url = 'https://www.google.com/search?q=test';
        expect(service.cleanUrl(url), equals(url));
      });

      test('removes all query params if all are tracking', () {
        final result = service.cleanUrl(
          'https://www.google.com/page?utm_source=test&utm_medium=email',
        );
        expect(result, equals('https://www.google.com/page'));
      });

      test('does not modify URLs that do not match provider urlPattern', () {
        final url = 'https://example.org/page?utm_source=test';
        expect(service.cleanUrl(url), equals(url));
      });
    });

    group('exceptions', () {
      setUp(() {
        service.loadRulesFromJson({
          'providers': {
            'test': {
              'urlPattern': r'example\.com',
              'completeProvider': false,
              'rules': [r'^utm_source$'],
              'rawRules': [],
              'exceptions': [r'example\.com/keep'],
              'redirections': [],
            },
          },
        });
      });

      test('skips cleaning for exception URLs', () {
        final url = 'https://example.com/keep?utm_source=test';
        expect(service.cleanUrl(url), equals(url));
      });

      test('still cleans non-exception URLs', () {
        final result = service.cleanUrl(
          'https://example.com/other?utm_source=test',
        );
        expect(result, equals('https://example.com/other'));
      });
    });

    group('completeProvider', () {
      setUp(() {
        service.loadRulesFromJson({
          'providers': {
            'blocked': {
              'urlPattern': r'tracker\.com',
              'completeProvider': true,
              'rules': [],
              'rawRules': [],
              'exceptions': [],
              'redirections': [],
            },
          },
        });
      });

      test('returns empty string for blocked providers', () {
        expect(service.cleanUrl('https://tracker.com/pixel'), equals(''));
      });

      test('does not block non-matching URLs', () {
        final url = 'https://example.com/page';
        expect(service.cleanUrl(url), equals(url));
      });
    });

    group('redirections', () {
      setUp(() {
        service.loadRulesFromJson({
          'providers': {
            'redirect': {
              'urlPattern': r'redirect\.example\.com',
              'completeProvider': false,
              'rules': [],
              'rawRules': [],
              'exceptions': [],
              'redirections': [r'redirect\.example\.com.*[?&]url=([^&]+)'],
            },
          },
        });
      });

      test('extracts redirect target from URL', () {
        final result = service.cleanUrl(
          'https://redirect.example.com/go?url=https%3A%2F%2Ftarget.com%2Fpage&tracking=123',
        );
        expect(result, equals('https://target.com/page'));
      });
    });

    group('rawRules', () {
      setUp(() {
        service.loadRulesFromJson({
          'providers': {
            'raw': {
              'urlPattern': r'example\.com',
              'completeProvider': false,
              'rules': [],
              'rawRules': [r'#tracking-[a-z]+'],
              'exceptions': [],
              'redirections': [],
            },
          },
        });
      });

      test('applies rawRules regex replacement', () {
        final result = service.cleanUrl(
          'https://example.com/page#tracking-abc',
        );
        expect(result, equals('https://example.com/page'));
      });
    });

    group('malformed URLs', () {
      test('handles empty string', () {
        service.loadRulesFromJson({
          'providers': {
            'test': {
              'urlPattern': r'.*',
              'completeProvider': false,
              'rules': [r'^utm_source$'],
              'rawRules': [],
              'exceptions': [],
              'redirections': [],
            },
          },
        });
        expect(service.cleanUrl(''), equals(''));
      });

      test('handles URL without query string', () {
        service.loadRulesFromJson({
          'providers': {
            'test': {
              'urlPattern': r'example\.com',
              'completeProvider': false,
              'rules': [r'^utm_source$'],
              'rawRules': [],
              'exceptions': [],
              'redirections': [],
            },
          },
        });
        final url = 'https://example.com/page';
        expect(service.cleanUrl(url), equals(url));
      });
    });

    group('hasRules', () {
      test('is false with empty providers', () {
        service.loadRulesFromJson({'providers': {}});
        expect(service.hasRules, isFalse);
      });

      test('is false with no providers key', () {
        service.loadRulesFromJson({});
        expect(service.hasRules, isFalse);
      });

      test('is true after loading valid rules', () {
        service.loadRulesFromJson({
          'providers': {
            'test': {
              'urlPattern': r'example\.com',
              'completeProvider': false,
              'rules': [],
              'rawRules': [],
              'exceptions': [],
              'redirections': [],
            },
          },
        });
        expect(service.hasRules, isTrue);
      });
    });
  });
}
