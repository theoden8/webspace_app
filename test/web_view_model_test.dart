import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';

void main() {
  group('WebViewModel', () {
    test('should initialize with default values', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
      );

      expect(model.initUrl, equals('https://example.com'));
      expect(model.currentUrl, equals('https://example.com'));
      expect(model.cookies, isEmpty);
      expect(model.javascriptEnabled, isTrue);
      expect(model.userAgent, equals(''));
      expect(model.thirdPartyCookiesEnabled, isFalse);
      expect(model.proxySettings.type, equals(ProxyType.DEFAULT));
      expect(model.siteId, isNotEmpty); // Auto-generated siteId
      expect(model.incognito, isFalse);
    });

    test('should serialize to JSON correctly', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        currentUrl: 'https://example.com/page',
        javascriptEnabled: false,
        userAgent: 'TestAgent/1.0',
        thirdPartyCookiesEnabled: true,
      );

      final json = model.toJson();

      expect(json['siteId'], equals(model.siteId)); // siteId included
      expect(json['initUrl'], equals('https://example.com'));
      expect(json['currentUrl'], equals('https://example.com/page'));
      expect(json['javascriptEnabled'], equals(false));
      expect(json['userAgent'], equals('TestAgent/1.0'));
      expect(json['thirdPartyCookiesEnabled'], equals(true));
      expect(json['incognito'], equals(false));
      expect(json['cookies'], isList);
      expect(json['proxySettings'], isMap);
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com/page',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': false,
        'userAgent': 'TestAgent/1.0',
        'thirdPartyCookiesEnabled': true,
      };

      final model = WebViewModel.fromJson(json, null);

      expect(model.initUrl, equals('https://example.com'));
      expect(model.currentUrl, equals('https://example.com/page'));
      expect(model.javascriptEnabled, equals(false));
      expect(model.userAgent, equals('TestAgent/1.0'));
      expect(model.thirdPartyCookiesEnabled, equals(true));
    });

    test('should round-trip through JSON correctly', () {
      final original = WebViewModel(
        initUrl: 'https://test.com',
        currentUrl: 'https://test.com/path',
        cookies: [
          Cookie(name: 'session', value: 'abc123'),
          Cookie(name: 'preference', value: 'dark_mode'),
        ],
        javascriptEnabled: false,
        userAgent: 'Custom/1.0',
        thirdPartyCookiesEnabled: true,
      );

      final json = original.toJson();
      final restored = WebViewModel.fromJson(json, null);

      expect(restored.siteId, equals(original.siteId)); // siteId preserved
      expect(restored.initUrl, equals(original.initUrl));
      expect(restored.currentUrl, equals(original.currentUrl));
      expect(restored.cookies.length, equals(original.cookies.length));
      expect(restored.cookies[0].name, equals('session'));
      expect(restored.cookies[1].name, equals('preference'));
      expect(restored.javascriptEnabled, equals(original.javascriptEnabled));
      expect(restored.userAgent, equals(original.userAgent));
      expect(restored.thirdPartyCookiesEnabled, equals(original.thirdPartyCookiesEnabled));
      expect(restored.incognito, equals(original.incognito));
    });
  });

  group('extractDomain', () {
    test('should extract domain from URL', () {
      expect(extractDomain('https://example.com'), equals('example.com'));
      expect(extractDomain('https://www.example.com/path'), equals('www.example.com'));
      expect(extractDomain('http://sub.domain.example.org:8080/'), equals('sub.domain.example.org'));
    });

    test('should handle invalid URLs gracefully', () {
      expect(extractDomain('not-a-url'), equals('not-a-url'));
      expect(extractDomain(''), equals(''));
    });

    test('should handle URLs without host', () {
      // file:// URLs have no host, so extractDomain returns the full URL
      expect(extractDomain('file:///path/to/file'), equals('file:///path/to/file'));
    });
  });
}
