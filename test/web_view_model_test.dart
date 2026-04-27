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
      expect(model.clearUrlEnabled, isTrue);
      expect(model.dnsBlockEnabled, isTrue);
      expect(model.contentBlockEnabled, isTrue);
      expect(model.localCdnEnabled, isTrue);
      expect(model.fullscreenMode, isFalse);
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
      expect(json['clearUrlEnabled'], equals(true));
      expect(json['dnsBlockEnabled'], equals(true));
      expect(json['contentBlockEnabled'], equals(true));
      expect(json['localCdnEnabled'], equals(true));
      expect(json['fullscreenMode'], equals(false));
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
      expect(restored.clearUrlEnabled, equals(original.clearUrlEnabled));
      expect(restored.dnsBlockEnabled, equals(original.dnsBlockEnabled));
      expect(restored.contentBlockEnabled, equals(original.contentBlockEnabled));
      expect(restored.localCdnEnabled, equals(original.localCdnEnabled));
      expect(restored.fullscreenMode, equals(original.fullscreenMode));
    });

    test('clearUrlEnabled defaults to true when missing from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.clearUrlEnabled, isTrue);
    });

    test('clearUrlEnabled false is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        clearUrlEnabled: false,
      );

      final json = model.toJson();
      expect(json['clearUrlEnabled'], equals(false));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.clearUrlEnabled, isFalse);
    });

    test('dnsBlockEnabled defaults to true when missing from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.dnsBlockEnabled, isTrue);
    });

    test('dnsBlockEnabled false is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        dnsBlockEnabled: false,
      );

      final json = model.toJson();
      expect(json['dnsBlockEnabled'], equals(false));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.dnsBlockEnabled, isFalse);
    });

    test('contentBlockEnabled defaults to true when missing from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.contentBlockEnabled, isTrue);
    });

    test('contentBlockEnabled false is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        contentBlockEnabled: false,
      );

      final json = model.toJson();
      expect(json['contentBlockEnabled'], equals(false));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.contentBlockEnabled, isFalse);
    });

    test('localCdnEnabled defaults to true when missing from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.localCdnEnabled, isTrue);
    });

    test('localCdnEnabled false is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        localCdnEnabled: false,
      );

      final json = model.toJson();
      expect(json['localCdnEnabled'], equals(false));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.localCdnEnabled, isFalse);
    });

    test('fullscreenMode defaults to false when missing from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.fullscreenMode, isFalse);
    });

    test('fullscreenMode true is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        fullscreenMode: true,
      );

      final json = model.toJson();
      expect(json['fullscreenMode'], equals(true));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.fullscreenMode, isTrue);
    });

    test('location spoof fields default to off and null', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.locationMode, equals(LocationMode.off));
      expect(model.spoofLatitude, isNull);
      expect(model.spoofLongitude, isNull);
      expect(model.spoofAccuracy, equals(50.0));
      expect(model.spoofTimezone, isNull);
      expect(model.webRtcPolicy, equals(WebRtcPolicy.defaultPolicy));
    });

    test('location spoof fields round-trip through JSON', () {
      final original = WebViewModel(
        initUrl: 'https://example.com',
        locationMode: LocationMode.spoof,
        spoofLatitude: 35.6762,
        spoofLongitude: 139.6503,
        spoofAccuracy: 25.0,
        spoofTimezone: 'Asia/Tokyo',
        webRtcPolicy: WebRtcPolicy.relayOnly,
      );

      final json = original.toJson();
      expect(json['locationMode'], equals('spoof'));
      expect(json['spoofLatitude'], equals(35.6762));
      expect(json['spoofLongitude'], equals(139.6503));
      expect(json['spoofAccuracy'], equals(25.0));
      expect(json['spoofTimezone'], equals('Asia/Tokyo'));
      expect(json['webRtcPolicy'], equals('relayOnly'));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.locationMode, equals(LocationMode.spoof));
      expect(restored.spoofLatitude, equals(35.6762));
      expect(restored.spoofLongitude, equals(139.6503));
      expect(restored.spoofAccuracy, equals(25.0));
      expect(restored.spoofTimezone, equals('Asia/Tokyo'));
      expect(restored.webRtcPolicy, equals(WebRtcPolicy.relayOnly));
    });

    test('location spoof fields default when missing from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.locationMode, equals(LocationMode.off));
      expect(model.spoofLatitude, isNull);
      expect(model.spoofLongitude, isNull);
      expect(model.spoofAccuracy, equals(50.0));
      expect(model.spoofTimezone, isNull);
      expect(model.webRtcPolicy, equals(WebRtcPolicy.defaultPolicy));
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
