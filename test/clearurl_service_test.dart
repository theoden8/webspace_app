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

    group('URL validation', () {
      setUp(() {
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
      });

      test('cleans valid http URL', () {
        final result = service.cleanUrl(
          'http://example.com/page?utm_source=test',
        );
        expect(result, equals('http://example.com/page'));
      });

      test('cleans valid https URL', () {
        final result = service.cleanUrl(
          'https://example.com/page?utm_source=test',
        );
        expect(result, equals('https://example.com/page'));
      });

      test('returns plain text unchanged', () {
        const text = 'just some plain text with utm_source in it';
        expect(service.cleanUrl(text), equals(text));
      });

      test('returns text with no scheme unchanged', () {
        const text = 'example.com/page?utm_source=test';
        expect(service.cleanUrl(text), equals(text));
      });

      test('returns ftp URL unchanged', () {
        const text = 'ftp://example.com/file?utm_source=test';
        expect(service.cleanUrl(text), equals(text));
      });

      test('returns javascript: URI unchanged', () {
        const text = 'javascript:alert(1)';
        expect(service.cleanUrl(text), equals(text));
      });

      test('returns data: URI unchanged', () {
        const text = 'data:text/html,<h1>hello</h1>';
        expect(service.cleanUrl(text), equals(text));
      });

      test('returns empty string unchanged when no providers match', () {
        // Load rules with a specific pattern that won't match empty string
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
        expect(service.cleanUrl(''), equals(''));
      });
    });

    group('hasRules', () {
      // After the introduction of built-in redirector providers
      // (LinkedIn safety/go, Google /url, DuckDuckGo /l/), hasRules
      // is always true after a load — the built-ins ship as part
      // of the parser even when the downloaded catalog is empty
      // or missing. The catalog is the source of *additional*
      // rules, not the source of *all* rules.
      test('is true even with empty providers catalog (built-ins always present)', () {
        service.loadRulesFromJson({'providers': {}});
        expect(service.hasRules, isTrue);
      });

      test('is true even with no providers key (built-ins always present)', () {
        service.loadRulesFromJson({});
        expect(service.hasRules, isTrue);
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

    group('built-in redirector providers', () {
      // The built-in providers ship with the service even when the
      // downloaded ClearURLs catalog is empty, missing, or
      // malformed. These tests load an empty providers map and
      // verify that known cross-domain redirectors still get
      // unwrapped to their destinations.
      setUp(() {
        service.loadRulesFromJson({'providers': {}});
      });

      test('LinkedIn safety/go: extracts the embedded destination URL', () {
        // The exact URL shape from a real LinkedIn messaging-thread
        // outbound link, including `trk` and `messageThreadUrn`.
        // ClearURLs upstream's linkedin provider strips `trk`, which
        // breaks the safety/go redirect on the server side. Our
        // built-in provider should win because it's prepended to
        // the providers list, and should return the decoded reddit
        // URL directly.
        const url =
            'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2FLocalLLaMA%2Fcomments%2F1suef7t%2Fanthropic_admits_to_have_made_hosted_models_more%2F&trk=flagship-messaging-web&messageThreadUrn=urn%3Ali%3AmessagingThread%3A2-NzI2NzYy';
        final cleaned = service.cleanUrl(url);
        expect(
          cleaned,
          equals(
              'https://www.reddit.com/r/LocalLLaMA/comments/1suef7t/anthropic_admits_to_have_made_hosted_models_more/'),
        );
      });

      test('LinkedIn safety/go: works when url= is the only param', () {
        const url =
            'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fexample.org%2F';
        expect(service.cleanUrl(url), equals('https://example.org/'));
      });

      test('LinkedIn safety/go: works on the bare linkedin.com host', () {
        // No www. subdomain.
        const url = 'https://linkedin.com/safety/go?url=https%3A%2F%2Fexample.org%2F';
        expect(service.cleanUrl(url), equals('https://example.org/'));
      });

      test('LinkedIn safety/go: leaves /safety/go without url= alone', () {
        // Without a url= param (the page-not-found state) we have
        // nothing to extract — return the input.
        const url = 'https://www.linkedin.com/safety/go?_l=en_US';
        expect(service.cleanUrl(url), equals(url));
      });

      test('Google /url: extracts the q= destination', () {
        const url =
            'https://www.google.com/url?q=https%3A%2F%2Fexample.org%2Fpage&sa=U';
        expect(service.cleanUrl(url), equals('https://example.org/page'));
      });

      test('Google /url: works on regional google domains', () {
        const url =
            'https://www.google.co.uk/url?q=https%3A%2F%2Fexample.org%2F';
        expect(service.cleanUrl(url), equals('https://example.org/'));
      });

      test('DuckDuckGo /l/: extracts the uddg= destination', () {
        const url =
            'https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.amazon.de%2F&rut=abc';
        expect(service.cleanUrl(url), equals('https://www.amazon.de/'));
      });

      test('does not match similar-shaped paths on other hosts', () {
        // /safety/go on a host that isn't linkedin.com — leave alone.
        const url = 'https://example.com/safety/go?url=https%3A%2F%2Fevil.com%2F';
        expect(service.cleanUrl(url), equals(url));
      });
    });
  });
}
