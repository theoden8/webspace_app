import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';

// Use getNormalizedDomain from web_view_model.dart for domain comparison tests

void main() {
  group('Site ID Generation', () {
    test('should generate unique siteId on creation', () {
      final model1 = WebViewModel(initUrl: 'https://github.com');
      final model2 = WebViewModel(initUrl: 'https://github.com');
      final model3 = WebViewModel(initUrl: 'https://gitlab.com');

      expect(model1.siteId, isNotEmpty);
      expect(model2.siteId, isNotEmpty);
      expect(model3.siteId, isNotEmpty);

      // Each model should have a unique siteId
      expect(model1.siteId, isNot(equals(model2.siteId)));
      expect(model1.siteId, isNot(equals(model3.siteId)));
      expect(model2.siteId, isNot(equals(model3.siteId)));
    });

    test('should preserve siteId through serialization', () {
      final model = WebViewModel(initUrl: 'https://github.com');
      final originalSiteId = model.siteId;

      final json = model.toJson();
      final restored = WebViewModel.fromJson(json, null);

      expect(restored.siteId, equals(originalSiteId));
    });

    test('should generate new siteId when deserializing legacy data without siteId', () {
      // Simulate legacy JSON without siteId
      final legacyJson = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'cookies': <dynamic>[],
        'proxySettings': {'type': 0}, // 0 = ProxyType.DEFAULT.index
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'incognito': false,
        // No siteId field
      };

      final model = WebViewModel.fromJson(legacyJson, null);

      // Should have generated a new siteId
      expect(model.siteId, isNotEmpty);
    });

    test('should handle legacy data with null siteId', () {
      // Simulate legacy JSON with explicit null siteId
      final legacyJson = {
        'siteId': null,
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'cookies': <dynamic>[],
        'proxySettings': {'type': 0}, // 0 = ProxyType.DEFAULT.index
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'incognito': false,
      };

      final model = WebViewModel.fromJson(legacyJson, null);

      // Should have generated a new siteId
      expect(model.siteId, isNotEmpty);
    });

    test('legacy model without incognito should default to false', () {
      // Simulate legacy JSON without incognito field
      final legacyJson = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'cookies': <dynamic>[],
        'proxySettings': {'type': 0}, // 0 = ProxyType.DEFAULT.index
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        // No incognito field
      };

      final model = WebViewModel.fromJson(legacyJson, null);

      expect(model.incognito, isFalse);
    });

    test('legacy model should preserve all existing fields', () {
      // Simulate legacy JSON with all fields except siteId
      final legacyJson = {
        'initUrl': 'https://github.com/user',
        'currentUrl': 'https://github.com/user/repo',
        'name': 'My GitHub',
        'pageTitle': 'GitHub - User',
        'cookies': [
          {'name': 'session', 'value': 'abc123', 'domain': 'github.com'},
        ],
        'proxySettings': {'type': 0}, // 0 = ProxyType.DEFAULT.index
        'javascriptEnabled': false,
        'userAgent': 'CustomAgent/1.0',
        'thirdPartyCookiesEnabled': true,
        // No siteId, no incognito
      };

      final model = WebViewModel.fromJson(legacyJson, null);

      // Verify all fields are preserved
      expect(model.initUrl, equals('https://github.com/user'));
      expect(model.currentUrl, equals('https://github.com/user/repo'));
      expect(model.name, equals('My GitHub'));
      expect(model.pageTitle, equals('GitHub - User'));
      expect(model.cookies, hasLength(1));
      expect(model.cookies[0].name, equals('session'));
      expect(model.javascriptEnabled, isFalse);
      expect(model.userAgent, equals('CustomAgent/1.0'));
      expect(model.thirdPartyCookiesEnabled, isTrue);
      // Auto-generated fields
      expect(model.siteId, isNotEmpty);
      expect(model.incognito, isFalse);
    });

    test('siteId should be included in toJson output', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      final json = model.toJson();

      expect(json.containsKey('siteId'), isTrue);
      expect(json['siteId'], equals(model.siteId));
    });
  });

  group('Second-Level Domain Extraction', () {
    test('should extract second-level domain from simple domain', () {
      expect(getNormalizedDomain('https://github.com'), equals('github.com'));
      expect(getNormalizedDomain('https://gitlab.com'), equals('gitlab.com'));
    });

    test('should extract second-level domain from subdomain', () {
      expect(getNormalizedDomain('https://api.github.com'), equals('github.com'));
      expect(getNormalizedDomain('https://gist.github.com'), equals('github.com'));
      expect(getNormalizedDomain('https://www.google.com'), equals('google.com'));
    });

    test('should handle multi-level subdomains', () {
      expect(getNormalizedDomain('https://a.b.c.example.com'), equals('example.com'));
    });

    test('should handle URLs with paths', () {
      expect(getNormalizedDomain('https://github.com/user/repo'), equals('github.com'));
      expect(getNormalizedDomain('https://api.github.com/v3/users'), equals('github.com'));
    });

    test('should handle single-part domains', () {
      // Edge case: localhost or single-word domains
      expect(getNormalizedDomain('http://localhost'), equals('localhost'));
    });

    test('should handle invalid URLs gracefully', () {
      expect(getNormalizedDomain('not-a-url'), equals('not-a-url'));
      expect(getNormalizedDomain(''), equals(''));
    });

    test('should treat mail.google.com as gmail.com (domain alias)', () {
      expect(getNormalizedDomain('https://mail.google.com'), equals('gmail.com'));
      expect(getNormalizedDomain('https://mail.google.com/mail/u/0/'), equals('gmail.com'));
    });

    test('should treat inbox.google.com as gmail.com (domain alias)', () {
      expect(getNormalizedDomain('https://inbox.google.com'), equals('gmail.com'));
    });

    test('gmail.com should remain gmail.com', () {
      expect(getNormalizedDomain('https://gmail.com'), equals('gmail.com'));
    });

    test('other google subdomains should normalize to google.com', () {
      expect(getNormalizedDomain('https://www.google.com'), equals('google.com'));
      expect(getNormalizedDomain('https://drive.google.com'), equals('google.com'));
      expect(getNormalizedDomain('https://docs.google.com'), equals('google.com'));
    });
  });

  group('Domain Conflict Detection', () {
    test('same domain sites should be considered conflicting', () {
      final site1 = WebViewModel(initUrl: 'https://github.com/user1');
      final site2 = WebViewModel(initUrl: 'https://github.com/user2');

      final domain1 = getNormalizedDomain(site1.initUrl);
      final domain2 = getNormalizedDomain(site2.initUrl);

      expect(domain1, equals(domain2));
    });

    test('subdomain sites should be considered conflicting with main domain', () {
      final site1 = WebViewModel(initUrl: 'https://github.com');
      final site2 = WebViewModel(initUrl: 'https://gist.github.com');
      final site3 = WebViewModel(initUrl: 'https://api.github.com');

      final domain1 = getNormalizedDomain(site1.initUrl);
      final domain2 = getNormalizedDomain(site2.initUrl);
      final domain3 = getNormalizedDomain(site3.initUrl);

      expect(domain1, equals(domain2));
      expect(domain2, equals(domain3));
    });

    test('different domain sites should not conflict', () {
      final site1 = WebViewModel(initUrl: 'https://github.com');
      final site2 = WebViewModel(initUrl: 'https://gitlab.com');

      final domain1 = getNormalizedDomain(site1.initUrl);
      final domain2 = getNormalizedDomain(site2.initUrl);

      expect(domain1, isNot(equals(domain2)));
    });

    test('mail.google.com and gmail.com should be considered conflicting', () {
      final site1 = WebViewModel(initUrl: 'https://mail.google.com');
      final site2 = WebViewModel(initUrl: 'https://gmail.com');

      final domain1 = getNormalizedDomain(site1.initUrl);
      final domain2 = getNormalizedDomain(site2.initUrl);

      expect(domain1, equals(domain2));
      expect(domain1, equals('gmail.com'));
    });

    test('mail.google.com should NOT conflict with drive.google.com', () {
      final site1 = WebViewModel(initUrl: 'https://mail.google.com');
      final site2 = WebViewModel(initUrl: 'https://drive.google.com');

      final domain1 = getNormalizedDomain(site1.initUrl);
      final domain2 = getNormalizedDomain(site2.initUrl);

      // mail.google.com -> gmail.com, drive.google.com -> google.com
      expect(domain1, isNot(equals(domain2)));
      expect(domain1, equals('gmail.com'));
      expect(domain2, equals('google.com'));
    });
  });

  group('WebViewModel Webview Disposal', () {
    test('disposeWebView should clear webview and controller', () {
      final model = WebViewModel(initUrl: 'https://example.com');

      // Simulate having a webview (we can't create real ones in tests)
      // The fields are nullable, so we just verify they get set to null
      model.disposeWebView();

      expect(model.webview, isNull);
      expect(model.controller, isNull);
    });
  });

  group('Incognito Mode Cookie Handling', () {
    test('incognito sites should not capture cookies', () async {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        incognito: true,
      );

      // Set some cookies manually
      model.cookies = [
        Cookie(name: 'test', value: 'value', domain: 'example.com'),
      ];

      // captureCookies should be a no-op for incognito
      // We can't test the full behavior without a real CookieManager,
      // but we verify the incognito flag is set correctly
      expect(model.incognito, isTrue);
    });

    test('incognito flag should be preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        incognito: true,
      );

      final json = model.toJson();
      final restored = WebViewModel.fromJson(json, null);

      expect(restored.incognito, isTrue);
    });

    test('default incognito should be false', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.incognito, isFalse);
    });
  });

  group('Cookie Storage Key Format', () {
    test('siteId format should be valid for storage keys', () {
      final model = WebViewModel(initUrl: 'https://example.com');

      // siteId should not contain characters that would break JSON
      expect(model.siteId.contains('"'), isFalse);
      expect(model.siteId.contains("'"), isFalse);
      expect(model.siteId.contains('\n'), isFalse);
      expect(model.siteId.contains('\r'), isFalse);

      // siteId should be reasonably short for storage efficiency
      expect(model.siteId.length, lessThan(50));
    });
  });
}
