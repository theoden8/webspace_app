import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/domain_claim.dart';
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
      expect(model.trackingProtectionEnabled, isTrue);
      expect(model.localCdnEnabled, isTrue);
      expect(model.fullscreenMode, isFalse);
      expect(model.htmlCachingEnabled, isFalse);
      expect(model.notificationsEnabled, isFalse);
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
      expect(json['trackingProtectionEnabled'], equals(true));
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

    test('domainClaims null by default; toJson omits it; fromJson stays null',
        () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.domainClaims, isNull);
      final json = m.toJson();
      expect(json.containsKey('domainClaims'), isFalse);
      final back = WebViewModel.fromJson(json, null);
      expect(back.domainClaims, isNull);
    });

    test(
        'effectiveDomainClaims synthesizes baseDomain claim from initUrl when null',
        () {
      final m = WebViewModel(initUrl: 'https://mail.example.org/inbox');
      expect(m.effectiveDomainClaims, hasLength(1));
      expect(m.effectiveDomainClaims.first.kind, DomainClaimKind.baseDomain);
      expect(m.effectiveDomainClaims.first.value, 'example.org');
    });

    test('explicit domainClaims persist through JSON round-trip', () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      m.domainClaims = [
        DomainClaim.exactHost('example.org'),
        DomainClaim.wildcardSubdomain('example.org'),
      ];
      final json = m.toJson();
      expect(json['domainClaims'], isA<List<dynamic>>());
      final back = WebViewModel.fromJson(json, null);
      expect(back.domainClaims, isNotNull);
      expect(back.domainClaims!, [
        DomainClaim.exactHost('example.org'),
        DomainClaim.wildcardSubdomain('example.org'),
      ]);
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
      expect(restored.trackingProtectionEnabled, equals(original.trackingProtectionEnabled));
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

    test('zoomPercent defaults to 100 and is omitted from JSON at default', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.zoomPercent, equals(kDefaultZoomPercent));
      expect(model.toJson().containsKey('zoomPercent'), isFalse);
      expect(
        WebViewModel.fromJson(model.toJson(), null).zoomPercent,
        equals(kDefaultZoomPercent),
      );
    });

    test('non-default zoomPercent is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        zoomPercent: 150,
      );

      final json = model.toJson();
      expect(json['zoomPercent'], equals(150));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.zoomPercent, equals(150));
    });

    test('zoomPercent out of range is clamped on deserialization', () {
      Map<String, dynamic> jsonWithZoom(int zoom) => {
            'initUrl': 'https://example.com',
            'cookies': [],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
            'zoomPercent': zoom,
          };

      final tooHigh = WebViewModel.fromJson(jsonWithZoom(5000), null);
      expect(tooHigh.zoomPercent, equals(kMaxZoomPercent));

      final tooLow = WebViewModel.fromJson(jsonWithZoom(1), null);
      expect(tooLow.zoomPercent, equals(kMinZoomPercent));
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

    test('trackingProtectionEnabled defaults to true when missing from JSON', () {
      // Backward-compat: existing sites stored before this field was
      // added must opt INTO Enhanced Tracking Protection on next launch
      // (default true) so anti-fingerprinting + forced tracker blocking
      // is on by default for upgraders, matching the constructor default.
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
      expect(model.trackingProtectionEnabled, isTrue);
    });

    test('trackingProtectionEnabled false is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        trackingProtectionEnabled: false,
      );

      final json = model.toJson();
      expect(json['trackingProtectionEnabled'], equals(false));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.trackingProtectionEnabled, isFalse);
    });

    test('letterboxEnabled defaults to false; omitted from JSON; round-trips',
        () {
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(m.letterboxEnabled, isFalse);
      expect(m.toJson().containsKey('letterboxEnabled'), isFalse);

      final on = WebViewModel(
        initUrl: 'https://example.com',
        letterboxEnabled: true,
      );
      expect(on.toJson()['letterboxEnabled'], isTrue);
      final back = WebViewModel.fromJson(on.toJson(), null);
      expect(back.letterboxEnabled, isTrue);
    });

    test('spoofWindowWidth/Height null by default; toJson omits them', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(m.spoofWindowWidth, isNull);
      expect(m.spoofWindowHeight, isNull);
      final json = m.toJson();
      expect(json.containsKey('spoofWindowWidth'), isFalse);
      expect(json.containsKey('spoofWindowHeight'), isFalse);
      final back = WebViewModel.fromJson(json, null);
      expect(back.spoofWindowWidth, isNull);
      expect(back.spoofWindowHeight, isNull);
    });

    test('explicit spoofWindowWidth/Height persist through JSON round-trip', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        spoofWindowWidth: 1280,
        spoofWindowHeight: 720,
      );
      final json = m.toJson();
      expect(json['spoofWindowWidth'], equals(1280));
      expect(json['spoofWindowHeight'], equals(720));
      final back = WebViewModel.fromJson(json, null);
      expect(back.spoofWindowWidth, equals(1280));
      expect(back.spoofWindowHeight, equals(720));
    });

    test('fingerprintResetNonce null by default; toJson omits it', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(m.fingerprintResetNonce, isNull);
      expect(m.toJson().containsKey('fingerprintResetNonce'), isFalse);
    });

    test('rerollFingerprint sets a fresh nonce that round-trips and changes',
        () {
      final m = WebViewModel(initUrl: 'https://example.com');
      m.rerollFingerprint();
      final first = m.fingerprintResetNonce;
      expect(first, isNotNull);
      expect(first, isNotEmpty);

      final back = WebViewModel.fromJson(m.toJson(), null);
      expect(back.fingerprintResetNonce, equals(first));

      m.rerollFingerprint();
      expect(m.fingerprintResetNonce, isNot(equals(first)));
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

    test('htmlCachingEnabled defaults to false when missing from JSON', () {
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
      expect(model.htmlCachingEnabled, isFalse);
    });

    test('htmlCachingEnabled true is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        htmlCachingEnabled: true,
      );

      final json = model.toJson();
      expect(json['htmlCachingEnabled'], equals(true));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.htmlCachingEnabled, isTrue);
    });

    test('notificationsEnabled defaults to false when missing from JSON', () {
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
      expect(model.notificationsEnabled, isFalse);
    });

    test('notificationsEnabled true is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        notificationsEnabled: true,
      );

      final json = model.toJson();
      expect(json['notificationsEnabled'], equals(true));

      final restored = WebViewModel.fromJson(json, null);
      expect(restored.notificationsEnabled, isTrue);
    });

    test('protectedContentAllowed defaults to null (ask) and toJson omits it',
        () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.protectedContentAllowed, isNull);
      expect(model.toJson().containsKey('protectedContentAllowed'), isFalse);

      final restored = WebViewModel.fromJson(model.toJson(), null);
      expect(restored.protectedContentAllowed, isNull);
    });

    test('protectedContentAllowed allow/block round-trips through JSON', () {
      for (final decision in [true, false]) {
        final model = WebViewModel(
          initUrl: 'https://example.com',
          protectedContentAllowed: decision,
        );
        final json = model.toJson();
        expect(json['protectedContentAllowed'], equals(decision));
        final restored = WebViewModel.fromJson(json, null);
        expect(restored.protectedContentAllowed, equals(decision));
      }
    });

    test('effectiveProtectedContentAllowed forces deny for archive-tier (ARCH-006)',
        () {
      final allowed = WebViewModel(
        initUrl: 'https://example.com',
        protectedContentAllowed: true,
        isArchiveTier: true,
      );
      // Stored value is preserved, but the effective value never grants
      // DRM for archive sites.
      expect(allowed.protectedContentAllowed, isTrue);
      expect(allowed.effectiveProtectedContentAllowed, isFalse);

      final appTier = WebViewModel(
        initUrl: 'https://example.com',
        protectedContentAllowed: true,
      );
      expect(appTier.effectiveProtectedContentAllowed, isTrue);
    });

    test('legacy backgroundPoll JSON migrates to notificationsEnabled', () {
      // Sites stored under the previous schema (separate backgroundPoll
      // toggle, notifications off) should still be polled and able to
      // fire notifications after upgrade.
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'backgroundPoll': true,
      };

      final model = WebViewModel.fromJson(json, null);
      expect(model.notificationsEnabled, isTrue);
    });

    test('location spoof fields default to off and null', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.locationMode, equals(LocationMode.off));
      expect(model.spoofLatitude, isNull);
      expect(model.spoofLongitude, isNull);
      expect(model.spoofAccuracy, equals(50.0));
      expect(model.spoofTimezone, isNull);
      expect(model.liveLocationGranularity, equals(LocationGranularity.gps));
      expect(model.webRtcPolicy, equals(WebRtcPolicy.defaultPolicy));
    });

    test('liveLocationGranularity round-trips when non-default', () {
      // Default gps: omitted from JSON so on-disk size stays the same
      // for users who never touch live mode.
      final defaultModel = WebViewModel(
        initUrl: 'https://example.com',
        locationMode: LocationMode.live,
      );
      final defaultJson = defaultModel.toJson();
      expect(defaultJson.containsKey('liveLocationGranularity'), isFalse,
          reason: 'gps is the default; omit to keep on-disk JSON byte-stable '
              'for users who never opt into approximate/gsm');

      final gsmModel = WebViewModel(
        initUrl: 'https://example.com',
        locationMode: LocationMode.live,
        liveLocationGranularity: LocationGranularity.gsm,
      );
      final gsmJson = gsmModel.toJson();
      expect(gsmJson['liveLocationGranularity'], equals('gsm'));

      final restored = WebViewModel.fromJson(gsmJson, null);
      expect(restored.liveLocationGranularity,
          equals(LocationGranularity.gsm));

      final approxModel = WebViewModel(
        initUrl: 'https://example.com',
        locationMode: LocationMode.live,
        liveLocationGranularity: LocationGranularity.approximate,
      );
      final approxJson = approxModel.toJson();
      expect(approxJson['liveLocationGranularity'], equals('approximate'));
      expect(WebViewModel.fromJson(approxJson, null).liveLocationGranularity,
          equals(LocationGranularity.approximate));
    });

    test('liveLocationGranularity defaults to gps when absent from JSON', () {
      // Older backups predate the field — they must rehydrate as gps.
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'cookies': [],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'locationMode': 'live',
      };
      final model = WebViewModel.fromJson(json, null);
      expect(model.liveLocationGranularity, equals(LocationGranularity.gps));
    });

    test('legacy "fine"/"coarse" JSON values migrate to gps/gsm', () {
      // Backups written before #326 used the old enum names. Reading
      // them must map "fine" → gps and "coarse" → gsm so existing users
      // don't silently land on the wrong tier on upgrade.
      Map<String, dynamic> base(String value) => {
            'initUrl': 'https://example.com',
            'currentUrl': 'https://example.com',
            'cookies': [],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
            'locationMode': 'live',
            'liveLocationGranularity': value,
          };
      expect(
          WebViewModel.fromJson(base('fine'), null).liveLocationGranularity,
          equals(LocationGranularity.gps));
      expect(
          WebViewModel.fromJson(base('coarse'), null).liveLocationGranularity,
          equals(LocationGranularity.gsm));
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

    group('incognito ephemerality (issue #298)', () {
      test('toJson omits currentUrl/pageTitle and zeroes cookies (INC-003)', () {
        final model = WebViewModel(
          initUrl: 'https://www.google.com/maps',
          currentUrl: 'https://www.google.com/maps/@40.7128,-74.0060,15z',
          cookies: [Cookie(name: 'session', value: 'abc')],
          incognito: true,
        )..pageTitle = 'Google Maps';

        final json = model.toJson();

        expect(json.containsKey('currentUrl'), isFalse,
            reason: 'currentUrl is the smoking gun: it would re-centre Maps '
                'on the spoofed location after restart');
        expect(json.containsKey('pageTitle'), isFalse);
        expect(json['cookies'], isEmpty);
        // Config the user typed must still survive a restart.
        expect(json['initUrl'], 'https://www.google.com/maps');
        expect(json['incognito'], isTrue);
      });

      test('non-incognito toJson keeps session state', () {
        final model = WebViewModel(
          initUrl: 'https://example.com',
          currentUrl: 'https://example.com/page',
          cookies: [Cookie(name: 'session', value: 'abc')],
          incognito: false,
        )..pageTitle = 'Example';

        final json = model.toJson();

        expect(json['currentUrl'], 'https://example.com/page');
        expect(json['pageTitle'], 'Example');
        expect((json['cookies'] as List), hasLength(1));
      });

      test(
          'fromJson with incognito + legacy currentUrl/cookies discards them (INC-004)',
          () {
        // This is the exact shape produced by builds before the toJson
        // fix: incognito=true, but currentUrl and cookies are persisted.
        final json = {
          'initUrl': 'https://www.google.com/maps',
          'currentUrl':
              'https://www.google.com/maps/@40.7128,-74.0060,15z',
          'pageTitle': 'Stale Title',
          'cookies': [
            {'name': 'session', 'value': 'leak'}
          ],
          'proxySettings': {'type': 0, 'address': null},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
          'incognito': true,
        };

        final model = WebViewModel.fromJson(json, null);

        expect(model.currentUrl, equals(model.initUrl),
            reason: 'incognito session must reset to initUrl on every load');
        expect(model.cookies, isEmpty);
        expect(model.pageTitle, isNull);
        expect(model.incognito, isTrue);
      });

      test('round-trip from incognito: deep URL never resurfaces', () {
        final original = WebViewModel(
          initUrl: 'https://www.google.com/maps',
          currentUrl: 'https://www.google.com/maps/@40.7128,-74.0060,15z',
          cookies: [Cookie(name: 'session', value: 'abc')],
          incognito: true,
        )..pageTitle = 'Maps';

        final restored =
            WebViewModel.fromJson(original.toJson(), null);

        expect(restored.currentUrl, equals(original.initUrl));
        expect(restored.cookies, isEmpty);
        expect(restored.pageTitle, isNull);
        expect(restored.siteId, equals(original.siteId));
        expect(restored.incognito, isTrue);
      });
    });

    group('alwaysOpenHome (banking case)', () {
      test('toJson omits currentUrl/pageTitle but keeps cookies (AOH-001/003)', () {
        final model = WebViewModel(
          initUrl: 'https://login.bank.example',
          currentUrl: 'https://login.bank.example/account/123',
          cookies: [Cookie(name: 'session', value: 'keep_me')],
          alwaysOpenHome: true,
        )..pageTitle = 'Account 123';

        final json = model.toJson();

        expect(json.containsKey('currentUrl'), isFalse);
        expect(json.containsKey('pageTitle'), isFalse);
        // The whole point of the toggle vs incognito: cookies survive.
        expect((json['cookies'] as List), hasLength(1));
        expect((json['cookies'] as List)[0]['name'], 'session');
        expect(json['alwaysOpenHome'], isTrue);
      });

      test('fromJson with alwaysOpenHome + legacy currentUrl strips it (AOH-002)', () {
        final json = {
          'initUrl': 'https://login.bank.example',
          'currentUrl': 'https://login.bank.example/account/123',
          'pageTitle': 'Stale Account',
          'cookies': [
            {'name': 'session', 'value': 'keep_me'}
          ],
          'proxySettings': {'type': 0, 'address': null},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
          'alwaysOpenHome': true,
        };

        final model = WebViewModel.fromJson(json, null);

        expect(model.currentUrl, equals(model.initUrl));
        expect(model.pageTitle, isNull);
        // Cookies preserved — distinguishes from incognito's INC-004.
        expect(model.cookies, hasLength(1));
        expect(model.cookies[0].name, 'session');
        expect(model.alwaysOpenHome, isTrue);
      });

      test('alwaysOpenHome defaults to false when missing from JSON', () {
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
        expect(model.alwaysOpenHome, isFalse);
      });

      test('non-flagged site keeps URL through round-trip', () {
        final original = WebViewModel(
          initUrl: 'https://example.com',
          currentUrl: 'https://example.com/deep',
          alwaysOpenHome: false,
          incognito: false,
        );

        final restored = WebViewModel.fromJson(original.toJson(), null);

        expect(restored.currentUrl, 'https://example.com/deep');
      });

      test('incognito + alwaysOpenHome: cookies cleared (incognito wins on cookies)', () {
        // AOH-005: incognito implies alwaysOpenHome; the URL drop overlaps
        // but the cookie wipe is incognito-only.
        final model = WebViewModel(
          initUrl: 'https://example.com',
          currentUrl: 'https://example.com/deep',
          cookies: [Cookie(name: 's', value: 'v')],
          incognito: true,
          alwaysOpenHome: true,
        );

        final json = model.toJson();

        expect(json.containsKey('currentUrl'), isFalse);
        expect(json['cookies'], isEmpty);
      });
    });

    // Defensive deserialization: malformed prefs blobs from partial writes
    // or external backups must not crash boot. Pairs with the per-entry
    // try/catch in `_loadWebViewModels`.
    group('fromJson tolerates missing/null fields', () {
      Map<String, dynamic> baseJson() => {
            'initUrl': 'https://example.com',
            'name': 'Example',
            'proxySettings': {'type': 0},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
            'incognito': false,
            'clearUrlEnabled': true,
            'dnsBlockEnabled': true,
            'contentBlockEnabled': true,
            'blockAutoRedirects': true,
          };

      test('missing cookies key falls back to empty list', () {
        final json = baseJson();
        // No 'cookies' key at all.
        final model = WebViewModel.fromJson(json, null);
        expect(model.cookies, isEmpty);
      });

      test('null cookies value falls back to empty list', () {
        final json = baseJson()..['cookies'] = null;
        final model = WebViewModel.fromJson(json, null);
        expect(model.cookies, isEmpty);
      });
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
