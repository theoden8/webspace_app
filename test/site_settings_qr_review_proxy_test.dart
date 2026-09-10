import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/settings/proxy.dart';

void main() {
  group('QR review sees exactly the proxy the apply path installs (SEC-005)', () {
    test('a numeric-string type is reviewed as the proxy it decodes to', () {
      final proxy = SiteSettingsQrCodec.reviewProxy({
        'initUrl': 'https://portal.example',
        'proxySettings': {'type': '1', 'address': 'proxy.attacker.example:8080'},
      });
      expect(proxy, isNotNull);
      expect(proxy!.type, ProxyType.HTTP);
      expect(proxy.address, 'proxy.attacker.example:8080');
    });

    test('an int Tor type is reviewed even though it carries no address', () {
      final proxy = SiteSettingsQrCodec.reviewProxy({
        'proxySettings': {'type': ProxyType.TOR.index},
      });
      expect(proxy?.type, ProxyType.TOR);
    });

    test('DEFAULT or absent proxy produces no review line', () {
      expect(
        SiteSettingsQrCodec.reviewProxy({
          'proxySettings': {'type': ProxyType.DEFAULT.index}
        }),
        isNull,
      );
      expect(SiteSettingsQrCodec.reviewProxy({'initUrl': 'https://a'}), isNull);
    });
  });

  group('decode rejects proxy fields the review could misread', () {
    Map<String, dynamic> payload(Map<String, dynamic> proxy) => {
          'initUrl': 'https://portal.example',
          'proxySettings': proxy,
        };

    test('a non-int type is refused outright', () {
      final encoded = SiteSettingsQrCodec.encode(payload({
        'type': '1',
        'address': 'p:8080',
      }));
      expect(SiteSettingsQrCodec.decode(encoded), isNull);
    });

    test('an out-of-range type is refused', () {
      final encoded = SiteSettingsQrCodec.encode(payload({
        'type': 99,
        'address': 'p:8080',
      }));
      expect(SiteSettingsQrCodec.decode(encoded), isNull);
    });

    test('a non-string address is refused', () {
      final encoded = SiteSettingsQrCodec.encode(payload({
        'type': 1,
        'address': 8080,
      }));
      expect(SiteSettingsQrCodec.decode(encoded), isNull);
    });

    test('a well-formed proxy still decodes', () {
      final encoded = SiteSettingsQrCodec.encode(payload({
        'type': 1,
        'address': 'p:8080',
      }));
      final out = SiteSettingsQrCodec.decode(encoded);
      expect(out, isNotNull);
      expect((out!['proxySettings'] as Map)['address'], 'p:8080');
    });
  });
}
