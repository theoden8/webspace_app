import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/capture_fakes.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/web_view_model_json.dart';
import 'package:webspace/settings/site_ids.dart';

const _url = 'https://example.com';

/// A stored site as builds before the per-site toggles wrote it, plus [extra].
Map<String, dynamic> _bareJson([Map<String, dynamic> extra = const {}]) => {
      'initUrl': _url,
      'cookies': [],
      'proxySettings': {'type': 0, 'address': null},
      'javascriptEnabled': true,
      'userAgent': '',
      'thirdPartyCookiesEnabled': false,
      ...extra,
    };

/// [_bareJson] with the current URL its last session left.
Map<String, dynamic> _legacyJson([Map<String, dynamic> extra = const {}]) =>
    _bareJson({'currentUrl': _url, ...extra});

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

      final model = WebViewModel.fromJson(json, stateSetterF: null);

      expect(model.initUrl, equals('https://example.com'));
      expect(model.currentUrl, equals('https://example.com/page'));
      expect(model.javascriptEnabled, equals(false));
      expect(model.userAgent, equals('TestAgent/1.0'));
      expect(model.thirdPartyCookiesEnabled, equals(true));
    });

    group('per-site blocker masks (DNS-020, CB-015)', () {
      test('default to following the app-wide configuration', () {
        final m = WebViewModel(initUrl: 'https://example.com');
        expect(m.dnsBlockLevel, isNull);
        expect(m.disabledFilterLists, isEmpty);
      });

      test('round-trip through JSON', () {
        final m = WebViewModel(initUrl: 'https://example.com')
          ..dnsBlockLevel = 2
          ..disabledFilterLists = {'easylist', 'fanboy-social'};
        final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
        expect(back.dnsBlockLevel, 2);
        expect(back.disabledFilterLists, {'easylist', 'fanboy-social'});
      });

      test('a null level round-trips as null, not as Off', () {
        final m = WebViewModel(initUrl: 'https://example.com');
        final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
        expect(back.dnsBlockLevel, isNull,
            reason: 'null follows the app level; 0 would mean blocking off');
      });

      test('level 0 survives as an explicit Off', () {
        final m = WebViewModel(initUrl: 'https://example.com')
          ..dnsBlockLevel = 0;
        expect(
            WebViewModel.fromJson(m.toJson(), stateSetterF: null).dnsBlockLevel,
            0);
      });

      test('a level outside 0..5 reads as following the app setting', () {
        // A hand-edited backup or a future build's wider range must not
        // become an out-of-range block posture.
        for (final bad in [-1, 6, 99]) {
          final json = WebViewModel(initUrl: 'https://example.com').toJson()
            ..['dnsBlockLevel'] = bad;
          expect(WebViewModel.fromJson(json, stateSetterF: null).dnsBlockLevel,
              isNull,
              reason: 'level $bad');
        }
      });

      test('a non-integer level reads as following the app setting', () {
        final json = WebViewModel(initUrl: 'https://example.com').toJson()
          ..['dnsBlockLevel'] = 'three';
        expect(WebViewModel.fromJson(json, stateSetterF: null).dnsBlockLevel,
            isNull);
      });

      test('a malformed list selection degrades to empty', () {
        for (final bad in [<dynamic>[1, 2], 'easylist', <String, String>{}]) {
          final json = WebViewModel(initUrl: 'https://example.com').toJson()
            ..['disabledFilterLists'] = bad;
          final back = WebViewModel.fromJson(json, stateSetterF: null);
          expect(back.disabledFilterLists, isEmpty, reason: '$bad');
        }
      });

      test('the stored list selection is order-stable', () {
        final a = WebViewModel(initUrl: 'https://example.com')
          ..disabledFilterLists = {'b', 'a'};
        final b = WebViewModel(initUrl: 'https://example.com')
          ..disabledFilterLists = {'a', 'b'};
        expect(a.toJson()['disabledFilterLists'],
            b.toJson()['disabledFilterLists'],
            reason: 'set iteration order must not churn the persisted JSON');
      });

      test('archive-tier sites carry neither mask (ARCH-006)', () {
        final m = WebViewModel(initUrl: 'https://example.com')
          ..dnsBlockLevel = 1
          ..disabledFilterLists = {'easylist'}
          ..isArchiveTier = true;
        expect(m.effectiveDnsBlockLevel, isNull);
        expect(m.effectiveDisabledFilterLists, isEmpty);
        expect(m.dnsBlockLevel, 1, reason: 'the stored intent is untouched');
      });
    });

    test('domainClaims null by default; toJson omits it; fromJson stays null',
        () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.domainClaims, isNull);
      final json = m.toJson();
      expect(json.containsKey('domainClaims'), isFalse);
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.domainClaims, isNull);
    });

    test('tabBarButtonCorner null by default; toJson omits it; round-trips',
        () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.tabBarButtonCorner, isNull);
      expect(m.toJson().containsKey('tabBarButtonCorner'), isFalse);

      m.tabBarButtonCorner = TabBarCorner.topLeft;
      final json = m.toJson();
      expect(json['tabBarButtonCorner'], 'topLeft');
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.tabBarButtonCorner, TabBarCorner.topLeft);
    });

    test('legacy per-site tabBarButtonOnRight bool maps to a bottom corner',
        () {
      final base = {
        'initUrl': 'https://example.org/',
        'cookies': <dynamic>[],
        'proxySettings': {'type': 0, 'address': null},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };
      expect(
        WebViewModel.fromJson({...base, 'tabBarButtonOnRight': true},
                stateSetterF: null)
            .tabBarButtonCorner,
        TabBarCorner.bottomRight,
      );
      expect(
        WebViewModel.fromJson({...base, 'tabBarButtonOnRight': false},
                stateSetterF: null)
            .tabBarButtonCorner,
        TabBarCorner.bottomLeft,
      );
      expect(
        WebViewModel.fromJson(base, stateSetterF: null).tabBarButtonCorner,
        isNull,
      );
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
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.domainClaims, isNotNull);
      expect(back.domainClaims!, [
        DomainClaim.exactHost('example.org'),
        DomainClaim.wildcardSubdomain('example.org'),
      ]);
    });

    test('externalLinkMode defaults to in-app; toJson omits the default', () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.externalLinkMode, ExternalLinkMode.inApp);
      expect(m.toJson().containsKey('externalLinkMode'), isFalse,
          reason: 'omitting the default keeps on-disk JSON byte-stable');
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.externalLinkMode, ExternalLinkMode.inApp);
    });

    test('externalLinkMode round-trips through JSON', () {
      for (final mode in [ExternalLinkMode.browser, ExternalLinkMode.block]) {
        final json =
            WebViewModel(initUrl: 'https://example.org/', externalLinkMode: mode)
                .toJson();
        expect(json['externalLinkMode'], mode.name);
        expect(json.containsKey('externalLinksInBrowser'), isFalse);
        expect(WebViewModel.fromJson(json, stateSetterF: null).externalLinkMode,
            mode);
      }
    });

    test('legacy externalLinksInBrowser reads as the browser mode', () {
      final json = WebViewModel(initUrl: 'https://example.org/').toJson();
      expect(
        WebViewModel.fromJson({...json, 'externalLinksInBrowser': true},
                stateSetterF: null)
            .externalLinkMode,
        ExternalLinkMode.browser,
      );
      expect(
        WebViewModel.fromJson({...json, 'externalLinksInBrowser': false},
                stateSetterF: null)
            .externalLinkMode,
        ExternalLinkMode.inApp,
      );
      expect(
        WebViewModel.fromJson({
          ...json,
          'externalLinksInBrowser': true,
          'externalLinkMode': 'block',
        }, stateSetterF: null).externalLinkMode,
        ExternalLinkMode.block,
        reason: 'the new field wins over the bool it replaced',
      );
    });

    test('an unknown or wrong-typed externalLinkMode reads as in-app', () {
      final json = WebViewModel(initUrl: 'https://example.org/').toJson();
      for (final odd in <Object>['sideways', 3, true]) {
        expect(
          WebViewModel.fromJson({...json, 'externalLinkMode': odd},
                  stateSetterF: null)
              .externalLinkMode,
          ExternalLinkMode.inApp,
        );
      }
    });

    test('routing applies only in the in-app mode', () {
      final m = WebViewModel(
          initUrl: 'https://example.org/', routeOutboundLinks: true);
      expect(m.effectiveRouteOutboundLinks, isTrue);
      m.externalLinkMode = ExternalLinkMode.browser;
      expect(m.effectiveRouteOutboundLinks, isFalse);
      m.externalLinkMode = ExternalLinkMode.block;
      expect(m.effectiveRouteOutboundLinks, isFalse);
      expect(m.routeOutboundLinks, isTrue,
          reason: 'the stored switch is kept for when the mode comes back');
    });

    test('backgroundAudioEnabled defaults off; toJson omits the default '
        '(BGAUDIO-001)', () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.backgroundAudioEnabled, isFalse);
      expect(m.toJson().containsKey('backgroundAudioEnabled'), isFalse,
          reason: 'omitting the default keeps on-disk JSON byte-stable');
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.backgroundAudioEnabled, isFalse);
    });

    test('backgroundAudioEnabled=true survives the settings-save round-trip '
        '(BGAUDIO-001)', () {
      // Mirrors what SettingsScreen._saveSettings does: flip the field on the
      // model, persist via toJson, rehydrate. If this regressed, a user who
      // enabled the toggle would still see App-lifecycle pause the site
      // (jsPause=true) after a restart.
      final m = WebViewModel(initUrl: 'https://example.org/');
      m.backgroundAudioEnabled = true;
      final json = m.toJson();
      expect(json['backgroundAudioEnabled'], isTrue);
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.backgroundAudioEnabled, isTrue);
      expect(back.effectiveBackgroundAudioEnabled, isTrue,
          reason: 'the lifecycle engine reads effectiveBackgroundAudioEnabled');
    });

    test('backgroundAudioEnabled absent in legacy JSON defaults off', () {
      final legacy = WebViewModel(initUrl: 'https://example.org/').toJson()
        ..remove('backgroundAudioEnabled');
      expect(legacy.containsKey('backgroundAudioEnabled'), isFalse);
      expect(
          WebViewModel.fromJson(legacy, stateSetterF: null)
              .backgroundAudioEnabled,
          isFalse);
    });

    test('backgroundAudioEnabled forced off for archive-tier sites '
        '(ARCH-006)', () {
      final m = WebViewModel(
        initUrl: 'https://example.org/',
        backgroundAudioEnabled: true,
        isArchiveTier: true,
      );
      expect(m.backgroundAudioEnabled, isTrue,
          reason: 'the stored value is preserved');
      expect(m.effectiveBackgroundAudioEnabled, isFalse,
          reason: 'archive-tier sites never opt out of lifecycle pausing');
    });

    test('kioskMode defaults off (KIOSK-004)', () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.kioskMode, isFalse);
    });

    test('kioskMode=true round-trips through JSON (KIOSK-004)', () {
      final m = WebViewModel(
        initUrl: 'https://example.org/',
        kioskMode: true,
      );
      final json = m.toJson();
      expect(json['kioskMode'], isTrue);
      expect(WebViewModel.fromJson(json, stateSetterF: null).kioskMode, isTrue);
    });

    test('kioskMode absent in legacy JSON defaults off (KIOSK-004)', () {
      final legacy = WebViewModel(initUrl: 'https://example.org/').toJson()
        ..remove('kioskMode');
      expect(legacy.containsKey('kioskMode'), isFalse);
      expect(
          WebViewModel.fromJson(legacy, stateSetterF: null).kioskMode, isFalse);
    });

    test('tabsEnabled defaults on and stays out of the JSON (TAB-013)', () {
      final m = WebViewModel(initUrl: 'https://example.org/');
      expect(m.tabsEnabled, isTrue);
      expect(m.effectiveTabsEnabled, isTrue);
      expect(m.toJson().containsKey('tabsEnabled'), isFalse);
    });

    test('tabsEnabled=false round-trips through JSON (TAB-013)', () {
      final json =
          WebViewModel(initUrl: 'https://example.org/', tabsEnabled: false)
              .toJson();
      expect(json['tabsEnabled'], isFalse);
      expect(
          WebViewModel.fromJson(json, stateSetterF: null).tabsEnabled, isFalse);
    });

    test('a wrong-typed list entry is dropped, its neighbours kept', () {
      final json = WebViewModel(initUrl: 'https://example.org/').toJson()
        ..['cookies'] = [
          {'name': 'sid', 'value': 'a', 'domain': 'example.org'},
          {'name': 7, 'value': 'b'},
          {'name': 'c', 'value': 'c', 'isSecure': 'yes'},
        ]
        ..['blockedCookies'] = [
          {'name': 'track', 'domain': 'example.org'},
          {'name': 'track', 'domain': 3},
        ]
        ..['domainClaims'] = [
          {'kind': 'baseDomain', 'value': 'example.org'},
          {'kind': 'baseDomain', 'value': 42},
        ];
      final m = WebViewModel.fromJson(json, stateSetterF: null);
      expect(m.cookies.map((c) => c.name), ['sid']);
      expect(m.blockedCookies.map((c) => c.name), ['track']);
      expect(m.domainClaims?.map((c) => c.value), ['example.org']);
    });

    test('a wrong-typed tabsEnabled reads as absent (TAB-013)', () {
      final json = WebViewModel(initUrl: 'https://example.org/').toJson()
        ..['tabsEnabled'] = 'no';
      expect(
          WebViewModel.fromJson(json, stateSetterF: null).tabsEnabled, isTrue);
    });

    test('kiosk turns tabs off without forgetting them (TAB-013)', () {
      final m = WebViewModel(initUrl: 'https://example.org/', kioskMode: true);
      expect(m.effectiveTabsEnabled, isFalse);
      expect(m.tabsEnabled, isTrue, reason: 'the stored choice is kept');
      m.kioskMode = false;
      expect(m.effectiveTabsEnabled, isTrue);
    });

    test('full screen leaves tabs on (TAB-013)', () {
      final m =
          WebViewModel(initUrl: 'https://example.org/', fullscreenMode: true);
      expect(m.effectiveTabsEnabled, isTrue);
    });

    test('archive-tier sites keep browser-mode links in the app (ARCH-006)', () {
      final m = WebViewModel(
        initUrl: 'https://example.org/',
        externalLinkMode: ExternalLinkMode.browser,
        isArchiveTier: true,
      );
      expect(m.externalLinkMode, ExternalLinkMode.browser);
      expect(m.effectiveExternalLinkMode, ExternalLinkMode.inApp,
          reason: 'archive sites never hand a URL to the system browser');
      m.externalLinkMode = ExternalLinkMode.block;
      expect(m.effectiveExternalLinkMode, ExternalLinkMode.block,
          reason: 'blocking crosses no boundary');
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
      final restored = WebViewModel.fromJson(json, stateSetterF: null);

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

    for (final (key, byDefault, read, build) in <(
      String,
      bool,
      bool Function(WebViewModel),
      WebViewModel Function({required bool enabled}),
    )>[
      ('clearUrlEnabled', true, (m) => m.clearUrlEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, clearUrlEnabled: enabled)),
      ('dnsBlockEnabled', true, (m) => m.dnsBlockEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, dnsBlockEnabled: enabled)),
      ('contentBlockEnabled', true, (m) => m.contentBlockEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, contentBlockEnabled: enabled)),
      // Backward-compat: existing sites stored before this field was
      // added must opt INTO Enhanced Tracking Protection on next launch
      // (default true) so anti-fingerprinting + forced tracker blocking
      // is on by default for upgraders, matching the constructor default.
      ('trackingProtectionEnabled', true, (m) => m.trackingProtectionEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, trackingProtectionEnabled: enabled)),
      ('localCdnEnabled', true, (m) => m.localCdnEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, localCdnEnabled: enabled)),
      ('fullscreenMode', false, (m) => m.fullscreenMode,
          ({required enabled}) => WebViewModel(initUrl: _url, fullscreenMode: enabled)),
      ('htmlCachingEnabled', false, (m) => m.htmlCachingEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, htmlCachingEnabled: enabled)),
      ('notificationsEnabled', false, (m) => m.notificationsEnabled,
          ({required enabled}) => WebViewModel(initUrl: _url, notificationsEnabled: enabled)),
    ]) {
      test('$key defaults to $byDefault when missing from JSON', () {
        expect(read(WebViewModel.fromJson(_legacyJson(), stateSetterF: null)),
            byDefault);
      });

      test('$key ${!byDefault} is preserved through serialization', () {
        final json = build(enabled: !byDefault).toJson();
        expect(json[key], !byDefault);
        expect(
            read(WebViewModel.fromJson(json, stateSetterF: null)), !byDefault);
      });
    }

    test('zoomPercent defaults to 100 and is omitted from JSON at default', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.zoomPercent, equals(kDefaultZoomPercent));
      expect(model.toJson().containsKey('zoomPercent'), isFalse);
      expect(
        WebViewModel.fromJson(model.toJson(), stateSetterF: null).zoomPercent,
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

      final restored = WebViewModel.fromJson(json, stateSetterF: null);
      expect(restored.zoomPercent, equals(150));
    });

    test('zoomPercent out of range is clamped on deserialization', () {
int zoomOf(int zoom) =>
    WebViewModel.fromJson(_bareJson({'zoomPercent': zoom}), stateSetterF: null)
        .zoomPercent;
      expect(zoomOf(5000), equals(kMaxZoomPercent));
      expect(zoomOf(1), equals(kMinZoomPercent));
    });

    test('tracking protection forces third-party cookies off (ETP-024)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        thirdPartyCookiesEnabled: true,
        trackingProtectionEnabled: false,
      );
      expect(model.effectiveThirdPartyCookiesEnabled, isTrue);

      model.trackingProtectionEnabled = true;
      expect(model.effectiveThirdPartyCookiesEnabled, isFalse);
      // Stored, not erased: the user's own choice comes back when the
      // umbrella goes off again, and survives a backup round-trip.
      expect(model.thirdPartyCookiesEnabled, isTrue);
      expect(model.toJson()['thirdPartyCookiesEnabled'], isTrue);

      model.trackingProtectionEnabled = false;
      expect(model.effectiveThirdPartyCookiesEnabled, isTrue);
    });

    group('tracking protection behind a proxy forbids direct WebRTC (ETP-031)',
        () {
      tearDown(GlobalOutboundProxy.resetForTest);

      test('the site\'s own proxy raises Default to Relay only', () {
        final model = WebViewModel(
          initUrl: 'https://example.com',
          proxySettings: UserProxySettings(
              type: ProxyType.SOCKS5, address: '127.0.0.1:1080'),
        );
        expect(model.trackingProtectionEnabled, isTrue);
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.relayOnly);
        // Stored, not erased, so turning the umbrella off gives Default back.
        expect(model.webRtcPolicy, WebRtcPolicy.defaultPolicy);
        expect(model.toJson()['webRtcPolicy'], 'defaultPolicy');

        model.trackingProtectionEnabled = false;
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.defaultPolicy);
      });

      test('a site left on DEFAULT counts as proxied under the app-wide one',
          () {
        final model = WebViewModel(initUrl: 'https://example.com');
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.defaultPolicy);

        GlobalOutboundProxy.setForTest(
          UserProxySettings(type: ProxyType.HTTP, address: '10.0.0.1:8080'),
        );
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.relayOnly);
      });

      test('Tor counts as a proxy', () {
        final model = WebViewModel(
          initUrl: 'https://example.com',
          proxySettings: UserProxySettings(type: ProxyType.TOR),
        );
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.relayOnly);
      });

      test('Disabled is stricter and stays', () {
        final model = WebViewModel(
          initUrl: 'https://example.com',
          proxySettings: UserProxySettings(type: ProxyType.TOR),
          webRtcPolicy: WebRtcPolicy.disabled,
        );
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.disabled);
      });

      test('no proxy leaves the stored policy alone', () {
        final model = WebViewModel(initUrl: 'https://example.com');
        expect(model.proxySettings.type, ProxyType.DEFAULT);
        expect(model.effectiveWebRtcPolicy, WebRtcPolicy.defaultPolicy);
      });
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
      final back = WebViewModel.fromJson(on.toJson(), stateSetterF: null);
      expect(back.letterboxEnabled, isTrue);
    });

    test('spoofWindowWidth/Height null by default; toJson omits them', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(m.spoofWindowWidth, isNull);
      expect(m.spoofWindowHeight, isNull);
      final json = m.toJson();
      expect(json.containsKey('spoofWindowWidth'), isFalse);
      expect(json.containsKey('spoofWindowHeight'), isFalse);
      final back = WebViewModel.fromJson(json, stateSetterF: null);
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
      final back = WebViewModel.fromJson(json, stateSetterF: null);
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

      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.fingerprintResetNonce, equals(first));

      m.rerollFingerprint();
      expect(m.fingerprintResetNonce, isNot(equals(first)));
    });

    test('blockScreenshots is off and unwritten by default', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.blockScreenshots, isFalse);
      expect(model.toJson().containsKey('blockScreenshots'), isFalse);
    });

    test('blockScreenshots true is preserved through serialization', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        blockScreenshots: true,
      );

      final json = model.toJson();
      expect(json['blockScreenshots'], isTrue);

      final restored = WebViewModel.fromJson(json, stateSetterF: null);
      expect(restored.blockScreenshots, isTrue);
    });

    test('a wrong-typed blockScreenshots reads as off', () {
      final model = WebViewModel.fromJson({
        'initUrl': 'https://example.com',
        'cookies': [],
        'blockScreenshots': 'yes',
      }, stateSetterF: null);
      expect(model.blockScreenshots, isFalse);
    });

    test('protectedContentAllowed defaults to null (ask) and toJson omits it',
        () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.protectedContentAllowed, isNull);
      expect(model.toJson().containsKey('protectedContentAllowed'), isFalse);

      final restored =
          WebViewModel.fromJson(model.toJson(), stateSetterF: null);
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
        final restored = WebViewModel.fromJson(json, stateSetterF: null);
        expect(restored.protectedContentAllowed, equals(decision));
      }
    });

    test('effectiveProtectedContentAllowed forces deny for archive-tier (ARCH-006)',
        () {
      final allowed = WebViewModel(
        initUrl: 'https://example.com',
        protectedContentAllowed: true,
        trackingProtectionEnabled: false,
        isArchiveTier: true,
      );
      // Stored value is preserved, but the effective value never grants
      // DRM for archive sites.
      expect(allowed.protectedContentAllowed, isTrue);
      expect(allowed.effectiveProtectedContentAllowed, isFalse);

      final appTier = WebViewModel(
        initUrl: 'https://example.com',
        protectedContentAllowed: true,
        trackingProtectionEnabled: false,
      );
      expect(appTier.effectiveProtectedContentAllowed, isTrue);
    });

    test('effectiveProtectedContentAllowed forces deny under Tracking Protection (ETP-023)',
        () {
      // Stored "allow" and stored "ask" (null) both become an unprompted
      // deny while the umbrella is on; the stored value is preserved.
      for (final stored in [true, null]) {
        final model = WebViewModel(
          initUrl: 'https://example.com',
          protectedContentAllowed: stored,
          trackingProtectionEnabled: true,
        );
        expect(model.protectedContentAllowed, equals(stored));
        expect(model.effectiveProtectedContentAllowed, isFalse);

        // Turning the umbrella off restores the stored decision.
        model.trackingProtectionEnabled = false;
        expect(model.effectiveProtectedContentAllowed, equals(stored));
      }
    });

    test('Tracking Protection forces no capture mode', () {
      // Unlike protected content (ETP-023), capture starts only after an
      // explicit per-site Allow or a picked file, so the umbrella leaves the
      // stored modes in effect.
      for (final kind in CaptureKind.values) {
        for (final mode in kind.modes) {
          final model = siteWith(kind, mode: mode)
            ..trackingProtectionEnabled = true;
          expect(kind.grantOf(model.effectiveCaptures).mode, mode);
        }
      }
    });

    test('legacy backgroundPoll JSON migrates to notificationsEnabled', () {
      // Sites stored under the previous schema (separate backgroundPoll
      // toggle, notifications off) should still be polled and able to
      // fire notifications after upgrade.
      final json = _legacyJson({'backgroundPoll': true});
      final model = WebViewModel.fromJson(json, stateSetterF: null);
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

      final restored = WebViewModel.fromJson(gsmJson, stateSetterF: null);
      expect(restored.liveLocationGranularity,
          equals(LocationGranularity.gsm));

      final approxModel = WebViewModel(
        initUrl: 'https://example.com',
        locationMode: LocationMode.live,
        liveLocationGranularity: LocationGranularity.approximate,
      );
      final approxJson = approxModel.toJson();
      expect(approxJson['liveLocationGranularity'], equals('approximate'));
      expect(
          WebViewModel.fromJson(approxJson, stateSetterF: null)
              .liveLocationGranularity,
          equals(LocationGranularity.approximate));
    });

    test('liveLocationGranularity defaults to gps when absent from JSON', () {
      // Older backups predate the field — they must rehydrate as gps.
      final json = _legacyJson({'locationMode': 'live'});
      final model = WebViewModel.fromJson(json, stateSetterF: null);
      expect(model.liveLocationGranularity, equals(LocationGranularity.gps));
    });

    test('legacy "fine"/"coarse" JSON values migrate to gps/gsm', () {
      // Backups written before #326 used the old enum names. Reading
      // them must map "fine" → gps and "coarse" → gsm so existing users
      // don't silently land on the wrong tier on upgrade.
      Map<String, dynamic> base(String value) =>
          _legacyJson({'locationMode': 'live', 'liveLocationGranularity': value});
      expect(
          WebViewModel.fromJson(base('fine'), stateSetterF: null)
              .liveLocationGranularity,
          equals(LocationGranularity.gps));
      expect(
          WebViewModel.fromJson(base('coarse'), stateSetterF: null)
              .liveLocationGranularity,
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

      final restored = WebViewModel.fromJson(json, stateSetterF: null);
      expect(restored.locationMode, equals(LocationMode.spoof));
      expect(restored.spoofLatitude, equals(35.6762));
      expect(restored.spoofLongitude, equals(139.6503));
      expect(restored.spoofAccuracy, equals(25.0));
      expect(restored.spoofTimezone, equals('Asia/Tokyo'));
      expect(restored.webRtcPolicy, equals(WebRtcPolicy.relayOnly));
    });

    test('location spoof fields default when missing from JSON', () {
      final json = _legacyJson();
      final model = WebViewModel.fromJson(json, stateSetterF: null);
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

        final model = WebViewModel.fromJson(json, stateSetterF: null);

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
            WebViewModel.fromJson(original.toJson(), stateSetterF: null);

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

        final model = WebViewModel.fromJson(json, stateSetterF: null);

        expect(model.currentUrl, equals(model.initUrl));
        expect(model.pageTitle, isNull);
        // Cookies preserved — distinguishes from incognito's INC-004.
        expect(model.cookies, hasLength(1));
        expect(model.cookies[0].name, 'session');
        expect(model.alwaysOpenHome, isTrue);
      });

      test('alwaysOpenHome defaults to false when missing from JSON', () {
        final model = WebViewModel.fromJson(_legacyJson(), stateSetterF: null);
        expect(model.alwaysOpenHome, isFalse);
      });

      test('non-flagged site keeps URL through round-trip', () {
        final original = WebViewModel(
          initUrl: 'https://example.com',
          currentUrl: 'https://example.com/deep',
          alwaysOpenHome: false,
          incognito: false,
        );

        final restored =
            WebViewModel.fromJson(original.toJson(), stateSetterF: null);

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
    // try/catch in `SiteListStore.load`.
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
        final model = WebViewModel.fromJson(json, stateSetterF: null);
        expect(model.cookies, isEmpty);
      });

      test('null cookies value falls back to empty list', () {
        final json = baseJson()..['cookies'] = null;
        final model = WebViewModel.fromJson(json, stateSetterF: null);
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

  group('fromJson siteId path-traversal hardening', () {
    Map<String, dynamic> baseJson(String siteId) =>
        _bareJson({'siteId': siteId});

    test('a valid minted-format siteId is preserved', () {
      final m =
          WebViewModel.fromJson(baseJson('abc123-x9y'), stateSetterF: null);
      expect(m.siteId, equals('abc123-x9y'));
    });

    test('a path-traversal siteId is replaced with a fresh safe id', () {
      final m = WebViewModel.fromJson(baseJson('../../../../shared_prefs/evil'),
          stateSetterF: null);
      expect(m.siteId, isNot(contains('/')));
      expect(m.siteId, isNot(contains('..')));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(m.siteId), isTrue);
    });

    test('siteId with a dot or separator is rejected and regenerated', () {
      for (final bad in ['a.b', 'a/b', r'a\b', 'a b', '', 'x' * 200]) {
        final m = WebViewModel.fromJson(baseJson(bad), stateSetterF: null);
        expect(m.siteId, isNot(equals(bad)));
        expect(RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(m.siteId), isTrue);
      }
    });

    test('sanitizedSiteId helper', () {
      expect(sanitizedSiteId('good-id_1'), equals('good-id_1'));
      expect(sanitizedSiteId('../x'), isNull);
      expect(sanitizedSiteId('a.b'), isNull);
      expect(sanitizedSiteId(42), isNull);
      expect(sanitizedSiteId(null), isNull);
    });
  });

  group('fromJson language header-injection hardening', () {
    Map<String, dynamic> baseJson(String language) =>
        _bareJson({'language': language});

    test('a valid BCP-47 language tag is preserved', () {
      for (final ok in ['en', 'fr', 'zh-CN', 'zh-TW', 'pt-BR']) {
        final m = WebViewModel.fromJson(baseJson(ok), stateSetterF: null);
        expect(m.language, equals(ok));
      }
    });

    test('a CRLF-bearing language is dropped to system default', () {
      final m = WebViewModel.fromJson(
          baseJson('en\r\nX-Injected: 1'), stateSetterF: null);
      expect(m.language, isNull);
    });

    test('sanitizedLanguageTag helper', () {
      expect(sanitizedLanguageTag('en'), equals('en'));
      expect(sanitizedLanguageTag('zh-CN'), equals('zh-CN'));
      expect(sanitizedLanguageTag('en\r\nEvil: 1'), isNull);
      expect(sanitizedLanguageTag('en, *;q=0.5'), isNull);
      expect(sanitizedLanguageTag(''), isNull);
      expect(sanitizedLanguageTag(42), isNull);
      expect(sanitizedLanguageTag(null), isNull);
    });
  });
}
