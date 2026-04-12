import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';

void main() {
  group('BlockedCookie', () {
    test('equality by name and domain', () {
      const a = BlockedCookie(name: '_ga', domain: '.google.com');
      const b = BlockedCookie(name: '_ga', domain: '.google.com');
      const c = BlockedCookie(name: '_ga', domain: '.facebook.com');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('serialization round-trip', () {
      const rule = BlockedCookie(name: 'session', domain: '.example.com');
      final json = rule.toJson();
      final restored = BlockedCookie.fromJson(json);

      expect(restored.name, equals('session'));
      expect(restored.domain, equals('.example.com'));
      expect(restored, equals(rule));
    });

    test('Set deduplication', () {
      final set = <BlockedCookie>{
        const BlockedCookie(name: '_ga', domain: '.google.com'),
        const BlockedCookie(name: '_ga', domain: '.google.com'),
        const BlockedCookie(name: '_gid', domain: '.google.com'),
      };

      expect(set.length, equals(2));
    });
  });

  group('WebViewModel.isCookieBlocked', () {
    test('exact domain match', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: '_ga', domain: '.example.com'),
        },
      );

      expect(model.isCookieBlocked('_ga', '.example.com'), isTrue);
      expect(model.isCookieBlocked('_ga', '.other.com'), isFalse);
      expect(model.isCookieBlocked('_gid', '.example.com'), isFalse);
    });

    test('subdomain matching', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: 'track', domain: 'example.com'),
        },
      );

      // Subdomain of blocked domain
      expect(model.isCookieBlocked('track', 'sub.example.com'), isTrue);
      // Exact match
      expect(model.isCookieBlocked('track', 'example.com'), isTrue);
      // Different domain
      expect(model.isCookieBlocked('track', 'notexample.com'), isFalse);
    });

    test('null domain never matches', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: '_ga', domain: '.example.com'),
        },
      );

      expect(model.isCookieBlocked('_ga', null), isFalse);
    });

    test('empty blockedCookies returns false fast', () {
      final model = WebViewModel(initUrl: 'https://example.com');

      expect(model.blockedCookies, isEmpty);
      expect(model.isCookieBlocked('anything', '.any.com'), isFalse);
    });

    test('multiple rules', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: '_ga', domain: '.google.com'),
          const BlockedCookie(name: '_fbp', domain: '.facebook.com'),
          const BlockedCookie(name: 'track', domain: '.example.com'),
        },
      );

      expect(model.isCookieBlocked('_ga', '.google.com'), isTrue);
      expect(model.isCookieBlocked('_fbp', '.facebook.com'), isTrue);
      expect(model.isCookieBlocked('track', '.example.com'), isTrue);
      expect(model.isCookieBlocked('_ga', '.facebook.com'), isFalse);
      expect(model.isCookieBlocked('session', '.google.com'), isFalse);
    });
  });

  group('WebViewModel serialization with blockedCookies', () {
    test('empty blockedCookies omitted from JSON', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      final json = model.toJson();

      expect(json.containsKey('blockedCookies'), isFalse);
    });

    test('blockedCookies included in JSON when non-empty', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: '_ga', domain: '.google.com'),
        },
      );
      final json = model.toJson();

      expect(json.containsKey('blockedCookies'), isTrue);
      expect(json['blockedCookies'], isList);
      expect((json['blockedCookies'] as List).length, equals(1));
    });

    test('round-trip preserves blockedCookies', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: '_ga', domain: '.google.com'),
          const BlockedCookie(name: '_fbp', domain: '.facebook.com'),
        },
      );

      final json = model.toJson();
      final restored = WebViewModel.fromJson(json, null);

      expect(restored.blockedCookies.length, equals(2));
      expect(
        restored.blockedCookies,
        contains(const BlockedCookie(name: '_ga', domain: '.google.com')),
      );
      expect(
        restored.blockedCookies,
        contains(const BlockedCookie(name: '_fbp', domain: '.facebook.com')),
      );
    });

    test('legacy JSON without blockedCookies deserializes with empty set', () {
      final legacyJson = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'cookies': <dynamic>[],
        'proxySettings': {'type': 0},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'incognito': false,
      };

      final model = WebViewModel.fromJson(legacyJson, null);

      expect(model.blockedCookies, isEmpty);
      expect(model.isCookieBlocked('_ga', '.google.com'), isFalse);
    });
  });

  group('Cookie blocking with real Cookie objects', () {
    test('isCookieBlocked filters matching cookies', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockedCookies: {
          const BlockedCookie(name: '_ga', domain: '.example.com'),
        },
      );

      final cookies = [
        Cookie(name: '_ga', value: 'GA1.2.123', domain: '.example.com'),
        Cookie(name: 'session', value: 'abc', domain: '.example.com'),
        Cookie(name: '_ga', value: 'GA1.2.456', domain: '.other.com'),
      ];

      final filtered = cookies
          .where((c) => !model.isCookieBlocked(c.name, c.domain))
          .toList();

      expect(filtered.length, equals(2));
      expect(filtered.map((c) => c.name), containsAll(['session', '_ga']));
      // The _ga on .other.com should pass through
      expect(filtered.any((c) => c.domain == '.other.com'), isTrue);
      // The _ga on .example.com should be blocked
      expect(
        filtered.any((c) => c.name == '_ga' && c.domain == '.example.com'),
        isFalse,
      );
    });
  });
}
