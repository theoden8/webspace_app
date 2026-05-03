import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('SiteSettingsQrCodec', () {
    test('encode then decode is a no-op for the shareable subset', () {
      final source = WebViewModel(
        initUrl: 'https://example.com/start',
        name: 'Example',
        javascriptEnabled: false,
        userAgent: 'TestAgent/1.0',
        thirdPartyCookiesEnabled: true,
        incognito: true,
        language: 'fr',
        clearUrlEnabled: false,
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        trackingProtectionEnabled: false,
        localCdnEnabled: false,
        blockAutoRedirects: false,
        fullscreenMode: true,
        notificationsEnabled: true,
        backgroundPoll: true,
        locationMode: LocationMode.spoof,
        spoofLatitude: 51.5074,
        spoofLongitude: -0.1278,
        spoofAccuracy: 25.0,
        spoofTimezone: 'Europe/London',
        spoofTimezoneFromLocation: true,
        webRtcPolicy: WebRtcPolicy.relayOnly,
        proxySettings: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: 'proxy.example.com:1080',
          username: 'alice',
          password: 'never-shared',
        ),
      );

      final shared = SiteSettingsQrCodec.shareableSubset(source.toJson());
      final encoded = SiteSettingsQrCodec.encode(shared);
      final decoded = SiteSettingsQrCodec.decode(encoded);

      expect(decoded, equals(shared));

      final hydrated = WebViewModel.fromJson(
        SiteSettingsQrCodec.hydrateForFromJson(decoded!),
        null,
      );

      expect(hydrated.initUrl, source.initUrl);
      expect(hydrated.name, source.name);
      expect(hydrated.javascriptEnabled, source.javascriptEnabled);
      expect(hydrated.userAgent, source.userAgent);
      expect(hydrated.thirdPartyCookiesEnabled,
          source.thirdPartyCookiesEnabled);
      expect(hydrated.incognito, source.incognito);
      expect(hydrated.language, source.language);
      expect(hydrated.clearUrlEnabled, source.clearUrlEnabled);
      expect(hydrated.dnsBlockEnabled, source.dnsBlockEnabled);
      expect(hydrated.contentBlockEnabled, source.contentBlockEnabled);
      expect(hydrated.trackingProtectionEnabled,
          source.trackingProtectionEnabled);
      expect(hydrated.localCdnEnabled, source.localCdnEnabled);
      expect(hydrated.blockAutoRedirects, source.blockAutoRedirects);
      expect(hydrated.fullscreenMode, source.fullscreenMode);
      expect(hydrated.notificationsEnabled, source.notificationsEnabled);
      expect(hydrated.backgroundPoll, source.backgroundPoll);
      expect(hydrated.locationMode, source.locationMode);
      expect(hydrated.spoofLatitude, source.spoofLatitude);
      expect(hydrated.spoofLongitude, source.spoofLongitude);
      expect(hydrated.spoofAccuracy, source.spoofAccuracy);
      expect(hydrated.spoofTimezone, source.spoofTimezone);
      expect(hydrated.spoofTimezoneFromLocation,
          source.spoofTimezoneFromLocation);
      expect(hydrated.webRtcPolicy, source.webRtcPolicy);
      expect(hydrated.proxySettings.type, ProxyType.SOCKS5);
      expect(hydrated.proxySettings.address, 'proxy.example.com:1080');
      expect(hydrated.proxySettings.username, 'alice');
      expect(hydrated.proxySettings.password, isNull);

      // Receiver mints a fresh siteId; cookies / scripts don't transfer.
      expect(hydrated.siteId, isNot(source.siteId));
      expect(hydrated.cookies, isEmpty);
      expect(hydrated.userScripts, isEmpty);
    });

    test('emits webspace://qr/site/v1/<payload> URI', () {
      final encoded = SiteSettingsQrCodec.encode({
        'initUrl': 'https://example.com',
      });
      expect(encoded, startsWith('webspace://qr/site/v1/'));
      expect(SiteSettingsQrCodec.looksLikeQrPayload(encoded), isTrue);
    });

    test('proxy password and secure cookies never appear in encoded output',
        () {
      final source = WebViewModel(
        initUrl: 'https://secure.example.com',
        proxySettings: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: 'proxy.example.com:1080',
          username: 'alice',
          password: 'super-secret-password',
        ),
      );

      final encoded = SiteSettingsQrCodec.encode(
        SiteSettingsQrCodec.shareableSubset(source.toJson()),
      );

      // Round-trip through the wire: rebuild the inner JSON from the URI
      // and assert the secret literals are absent — covers both encoded
      // and gunzipped views of the payload.
      final payload = encoded.split('/').last;
      final padded = payload + '=' * ((4 - payload.length % 4) % 4);
      final inner =
          utf8.decode(gzip.decode(base64Url.decode(padded)));

      expect(inner.contains('super-secret-password'), isFalse,
          reason: 'proxy password (PWD-005) must never ride the QR');
      expect(inner.contains('cookies'), isFalse,
          reason: 'cookies are stripped from the share');
    });

    test('user scripts are never included in encoded output', () {
      final source = WebViewModel(
        initUrl: 'https://example.com',
        userScripts: [
          UserScriptConfig(
            id: 'script-1',
            name: 'Custom Script',
            source: 'console.log("hello world");',
            enabled: true,
          ),
        ],
      );

      final shared = SiteSettingsQrCodec.shareableSubset(source.toJson());
      expect(shared.containsKey('userScripts'), isFalse);

      final encoded = SiteSettingsQrCodec.encode(shared);
      final payload = encoded.split('/').last;
      final padded = payload + '=' * ((4 - payload.length % 4) % 4);
      final inner =
          utf8.decode(gzip.decode(base64Url.decode(padded)));

      expect(inner.contains('console.log'), isFalse);
      expect(inner.contains('userScripts'), isFalse);
    });

    test('decode strips smuggled fields outside the allowlist', () {
      final hostile = {
        'initUrl': 'https://example.com',
        'cookies': [
          {'name': 'session', 'value': 'stolen', 'isSecure': true}
        ],
        'userScripts': [
          {'id': 'x', 'name': 'evil', 'source': 'alert(1)', 'enabled': true}
        ],
        'siteId': 'attacker-controlled-id',
      };

      // Hand-craft a wire payload that includes the smuggled fields.
      final compressed = gzip.encode(utf8.encode(jsonEncode(hostile)));
      final payload = base64Url.encode(compressed).replaceAll('=', '');
      final uri = 'webspace://qr/site/v1/$payload';

      final decoded = SiteSettingsQrCodec.decode(uri);
      expect(decoded, isNotNull);
      expect(decoded!['initUrl'], 'https://example.com');
      expect(decoded.containsKey('cookies'), isFalse);
      expect(decoded.containsKey('userScripts'), isFalse);
      expect(decoded.containsKey('siteId'), isFalse);
    });

    test('decode rejects malformed input', () {
      expect(SiteSettingsQrCodec.decode(''), isNull);
      expect(SiteSettingsQrCodec.decode('not a uri'), isNull);
      expect(SiteSettingsQrCodec.decode('https://example.com'), isNull);
      expect(SiteSettingsQrCodec.decode('webspace://qr/site/'), isNull);
      expect(SiteSettingsQrCodec.decode('webspace://qr/site/v1/'), isNull);
      expect(SiteSettingsQrCodec.decode('webspace://qr/site/v1/!!!'), isNull);
      expect(
          SiteSettingsQrCodec.decode(
              'webspace://qr/site/v1/${base64Url.encode(utf8.encode("not gzipped"))}'),
          isNull);
    });

    test('decode rejects payloads missing initUrl', () {
      final payload = {
        'name': 'Example',
        'javascriptEnabled': true,
      };
      final compressed = gzip.encode(utf8.encode(jsonEncode(payload)));
      final body = base64Url.encode(compressed).replaceAll('=', '');
      expect(
          SiteSettingsQrCodec.decode('webspace://qr/site/v1/$body'), isNull);
    });

    test('decode rejects future schema versions', () {
      final compressed =
          gzip.encode(utf8.encode(jsonEncode({'initUrl': 'https://e.com'})));
      final body = base64Url.encode(compressed).replaceAll('=', '');
      expect(
          SiteSettingsQrCodec.decode('webspace://qr/site/v999/$body'), isNull);
    });

    test('looksLikeQrPayload is strict about the prefix', () {
      expect(
          SiteSettingsQrCodec.looksLikeQrPayload(
              'webspace://qr/site/v1/abc'),
          isTrue);
      expect(
          SiteSettingsQrCodec.looksLikeQrPayload('https://example.com'),
          isFalse);
      expect(SiteSettingsQrCodec.looksLikeQrPayload(''), isFalse);
    });

    test('every WebViewModel.toJson key is classified', () {
      // Drift guard: when a new per-site field is added to WebViewModel,
      // the dev MUST decide whether it rides a shared QR. This test fails
      // if a `toJson` key isn't in either set.
      final fullToJson = WebViewModel(
        initUrl: 'https://example.com',
        spoofLatitude: 1.0,
        spoofLongitude: 1.0,
        spoofTimezone: 'UTC',
        spoofTimezoneFromLocation: true,
      ).toJson();

      final classified = {
        ...SiteSettingsQrCodec.includedKeys,
        ...SiteSettingsQrCodec.excludedKeys,
      };
      final unknown =
          fullToJson.keys.where((k) => !classified.contains(k)).toList();

      expect(unknown, isEmpty,
          reason:
              'Unclassified WebViewModel.toJson keys: $unknown. Add to '
              'SiteSettingsQrCodec.includedKeys or excludedKeys.');
    });

    test('encoded payload stays within QR Version 40 binary capacity', () {
      // Real-world worst case: every toggle flipped, long URL, long name,
      // long user-agent, full proxy with credentials, custom location.
      final maximal = WebViewModel(
        initUrl: 'https://${'sub.' * 12}example-with-a-fairly-long-domain.com'
            '/some/long/path?with=query&parameters=that-are-quite-long',
        name: 'A Reasonably Long Custom Site Name For Display Purposes',
        userAgent:
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, '
            'like Gecko) Chrome/130.0.0.0 Safari/537.36',
        language: 'en-US',
        spoofTimezone: 'America/Argentina/ComodRivadavia',
        spoofTimezoneFromLocation: true,
        spoofLatitude: 40.7127281,
        spoofLongitude: -74.0060152,
        spoofAccuracy: 12.5,
        locationMode: LocationMode.spoof,
        webRtcPolicy: WebRtcPolicy.disabled,
        proxySettings: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: 'a-fairly-long-proxy-host.example.com:65535',
          username: 'a-medium-length-username',
        ),
      );

      final encoded = SiteSettingsQrCodec.encode(
        SiteSettingsQrCodec.shareableSubset(maximal.toJson()),
      );

      // QR v40 binary mode at ECC-L holds 2,953 bytes. Even at ECC-H
      // (1,273 bytes) we leave plenty of headroom.
      expect(encoded.length, lessThan(900));
    });
  });
}
