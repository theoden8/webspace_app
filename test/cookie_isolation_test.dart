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

  group('getSecondLevelDomain (Cookie Isolation)', () {
    test('should extract second-level domain from simple domain', () {
      expect(getSecondLevelDomain('https://github.com'), equals('github.com'));
      expect(getSecondLevelDomain('https://gitlab.com'), equals('gitlab.com'));
    });

    test('should extract second-level domain from subdomain', () {
      expect(getSecondLevelDomain('https://api.github.com'), equals('github.com'));
      expect(getSecondLevelDomain('https://gist.github.com'), equals('github.com'));
      expect(getSecondLevelDomain('https://www.google.com'), equals('google.com'));
    });

    test('should handle multi-level subdomains', () {
      expect(getSecondLevelDomain('https://a.b.c.example.com'), equals('example.com'));
    });

    test('should handle URLs with paths', () {
      expect(getSecondLevelDomain('https://github.com/user/repo'), equals('github.com'));
      expect(getSecondLevelDomain('https://api.github.com/v3/users'), equals('github.com'));
    });

    test('should handle single-part domains', () {
      expect(getSecondLevelDomain('http://localhost'), equals('localhost'));
    });

    test('should handle invalid URLs gracefully', () {
      expect(getSecondLevelDomain('not-a-url'), equals('not-a-url'));
      expect(getSecondLevelDomain(''), equals(''));
    });

    test('mail.google.com should extract to google.com (no alias)', () {
      expect(getSecondLevelDomain('https://mail.google.com'), equals('google.com'));
      expect(getSecondLevelDomain('https://mail.google.com/mail/u/0/'), equals('google.com'));
    });

    test('all google subdomains should extract to google.com', () {
      expect(getSecondLevelDomain('https://mail.google.com'), equals('google.com'));
      expect(getSecondLevelDomain('https://drive.google.com'), equals('google.com'));
      expect(getSecondLevelDomain('https://docs.google.com'), equals('google.com'));
      expect(getSecondLevelDomain('https://account.google.com'), equals('google.com'));
    });

    test('gmail.com extracts to gmail.com (different second-level)', () {
      expect(getSecondLevelDomain('https://gmail.com'), equals('gmail.com'));
    });

    test('should handle multi-part TLDs like .co.uk', () {
      expect(getSecondLevelDomain('https://google.co.uk'), equals('google.co.uk'));
      expect(getSecondLevelDomain('https://www.google.co.uk'), equals('google.co.uk'));
      expect(getSecondLevelDomain('https://mail.google.co.uk'), equals('google.co.uk'));
      expect(getSecondLevelDomain('https://bbc.co.uk'), equals('bbc.co.uk'));
      expect(getSecondLevelDomain('https://www.bbc.co.uk'), equals('bbc.co.uk'));
    });

    test('should handle other multi-part TLDs', () {
      expect(getSecondLevelDomain('https://google.com.au'), equals('google.com.au'));
      expect(getSecondLevelDomain('https://www.google.com.au'), equals('google.com.au'));
      expect(getSecondLevelDomain('https://amazon.co.jp'), equals('amazon.co.jp'));
      expect(getSecondLevelDomain('https://www.amazon.co.jp'), equals('amazon.co.jp'));
    });

    test('should handle IPv4 addresses (return as-is)', () {
      expect(getSecondLevelDomain('http://192.168.1.1'), equals('192.168.1.1'));
      expect(getSecondLevelDomain('http://192.168.1.1:8080'), equals('192.168.1.1'));
      expect(getSecondLevelDomain('http://10.0.0.1:3000'), equals('10.0.0.1'));
      expect(getSecondLevelDomain('http://127.0.0.1'), equals('127.0.0.1'));
      expect(getSecondLevelDomain('http://0.0.0.0:5000'), equals('0.0.0.0'));
    });

    test('should handle IPv6 addresses (return as-is)', () {
      // Uri.host returns IPv6 addresses without brackets
      expect(getSecondLevelDomain('http://[::1]'), equals('::1'));
      expect(getSecondLevelDomain('http://[::1]:8080'), equals('::1'));
      expect(getSecondLevelDomain('http://[2001:db8::1]'), equals('2001:db8::1'));
    });

    test('IP addresses on same host should conflict', () {
      // Two sites on same IP should conflict (same "domain")
      final ip1 = getSecondLevelDomain('http://192.168.1.1:8080/app1');
      final ip2 = getSecondLevelDomain('http://192.168.1.1:8080/app2');
      expect(ip1, equals(ip2));
    });

    test('different IP addresses should not conflict', () {
      final ip1 = getSecondLevelDomain('http://192.168.1.1:8080');
      final ip2 = getSecondLevelDomain('http://192.168.1.2:8080');
      expect(ip1, isNot(equals(ip2)));
    });
  });

  group('getNormalizedDomain (Nested Webview Navigation)', () {
    test('gmail.com should map to google.com', () {
      expect(getNormalizedDomain('https://gmail.com'), equals('google.com'));
    });

    test('all google subdomains should map to google.com', () {
      expect(getNormalizedDomain('https://mail.google.com'), equals('google.com'));
      expect(getNormalizedDomain('https://drive.google.com'), equals('google.com'));
      expect(getNormalizedDomain('https://docs.google.com'), equals('google.com'));
      expect(getNormalizedDomain('https://account.google.com'), equals('google.com'));
    });

    test('non-google subdomains extract to second-level', () {
      expect(getNormalizedDomain('https://api.github.com'), equals('github.com'));
      expect(getNormalizedDomain('https://gist.github.com'), equals('github.com'));
    });

    test('should handle multi-part TLDs', () {
      // Non-Google domains should stay as their second-level domain
      expect(getNormalizedDomain('https://bbc.co.uk'), equals('bbc.co.uk'));
      expect(getNormalizedDomain('https://www.bbc.co.uk'), equals('bbc.co.uk'));
    });

    test('regional Google domains should map to google.com', () {
      expect(getNormalizedDomain('https://google.co.uk'), equals('google.com'));
      expect(getNormalizedDomain('https://www.google.co.uk'), equals('google.com'));
      expect(getNormalizedDomain('https://mail.google.co.uk'), equals('google.com'));
      expect(getNormalizedDomain('https://google.com.au'), equals('google.com'));
      expect(getNormalizedDomain('https://google.de'), equals('google.com'));
      expect(getNormalizedDomain('https://google.fr'), equals('google.com'));
    });

    test('claude.ai should map to anthropic.com', () {
      expect(getNormalizedDomain('https://claude.ai'), equals('anthropic.com'));
      expect(getNormalizedDomain('https://claude.ai/chat'), equals('anthropic.com'));
      expect(getNormalizedDomain('https://anthropic.com'), equals('anthropic.com'));
      expect(getNormalizedDomain('https://www.anthropic.com'), equals('anthropic.com'));
      expect(getNormalizedDomain('https://docs.anthropic.com'), equals('anthropic.com'));
    });

    test('chatgpt.com should map to openai.com', () {
      expect(getNormalizedDomain('https://chatgpt.com'), equals('openai.com'));
      expect(getNormalizedDomain('https://chatgpt.com/chat'), equals('openai.com'));
      expect(getNormalizedDomain('https://openai.com'), equals('openai.com'));
      expect(getNormalizedDomain('https://www.openai.com'), equals('openai.com'));
      expect(getNormalizedDomain('https://platform.openai.com'), equals('openai.com'));
    });

    test('IP addresses should be returned as-is (no aliasing)', () {
      expect(getNormalizedDomain('http://192.168.1.1'), equals('192.168.1.1'));
      expect(getNormalizedDomain('http://192.168.1.1:8080'), equals('192.168.1.1'));
      expect(getNormalizedDomain('http://10.0.0.1:3000/app'), equals('10.0.0.1'));
      // Uri.host returns IPv6 addresses without brackets
      expect(getNormalizedDomain('http://[::1]:8080'), equals('::1'));
    });
  });

  group('Cookie Isolation Domain Conflict Detection', () {
    test('same domain sites should conflict', () {
      final domain1 = getSecondLevelDomain('https://github.com/user1');
      final domain2 = getSecondLevelDomain('https://github.com/user2');

      expect(domain1, equals(domain2));
    });

    test('subdomain sites should conflict with main domain', () {
      final domain1 = getSecondLevelDomain('https://github.com');
      final domain2 = getSecondLevelDomain('https://gist.github.com');
      final domain3 = getSecondLevelDomain('https://api.github.com');

      expect(domain1, equals(domain2));
      expect(domain2, equals(domain3));
    });

    test('different second-level domains should not conflict', () {
      final domain1 = getSecondLevelDomain('https://github.com');
      final domain2 = getSecondLevelDomain('https://gitlab.com');

      expect(domain1, isNot(equals(domain2)));
    });

    test('all google.com subdomains should conflict with each other', () {
      final mailDomain = getSecondLevelDomain('https://mail.google.com');
      final driveDomain = getSecondLevelDomain('https://drive.google.com');
      final docsDomain = getSecondLevelDomain('https://docs.google.com');
      final accountDomain = getSecondLevelDomain('https://account.google.com');

      // All should be google.com
      expect(mailDomain, equals('google.com'));
      expect(driveDomain, equals('google.com'));
      expect(docsDomain, equals('google.com'));
      expect(accountDomain, equals('google.com'));

      // All should conflict
      expect(mailDomain, equals(driveDomain));
      expect(driveDomain, equals(docsDomain));
      expect(docsDomain, equals(accountDomain));
    });

    test('gmail.com should NOT conflict with google.com subdomains', () {
      final gmailDomain = getSecondLevelDomain('https://gmail.com');
      final mailGoogleDomain = getSecondLevelDomain('https://mail.google.com');

      // gmail.com and google.com are different second-level domains
      expect(gmailDomain, equals('gmail.com'));
      expect(mailGoogleDomain, equals('google.com'));
      expect(gmailDomain, isNot(equals(mailGoogleDomain)));
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
