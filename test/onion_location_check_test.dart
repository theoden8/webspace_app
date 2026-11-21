import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/services/onion_location.dart';
import 'package:webspace/services/onion_location_check.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_outbound.dart';

const _proton =
    'protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion';

final _tor = OutboundProxy.ofSite(UserProxySettings(type: ProxyType.TOR),
    site: SiteId('site-1'));

bool _proton1(Uri target) =>
    target.host == 'proton.me' || target.host.endsWith('.proton.me');

Future<OnionCheck> _check(String home) =>
    checkOnionLocation(home, proxy: _tor, withinSite: _proton1);

void main() {
  late FakeOutbound net;

  setUp(() {
    net = FakeOutbound();
    outboundHttp = net;
  });
  tearDown(resetOutboundHttp);

  group('checkOnionLocation (ONION-001)', () {
    test('reads the header through the site\'s Tor route', () async {
      net.responder = (_) => http.Response('<html></html>', 200,
          headers: {'onion-location': 'https://$_proton/'});
      final found = await _check('https://proton.me/mail');
      expect(found, isA<OnionAnnounced>());
      expect((found as OnionAnnounced).endpoint.to, 'https://$_proton');
      expect(net.lastQuery?.type, ProxyType.TOR);
    });

    test('reads the meta tag of the head', () async {
      net.responder = (_) => http.Response(
          '<head><meta http-equiv="onion-location" '
          'content="https://$_proton/"></head><body></body>', 200);
      expect(await _check('https://proton.me/'), isA<OnionAnnounced>());
    });

    test('an answer with no announcement is nothing announced', () async {
      net.responder = (_) => http.Response('<head></head>', 200);
      expect(await _check('https://proton.me/'), isA<NothingAnnounced>());
    });

    test('a redirect within the site is followed, one off it is refused',
        () async {
      net.responder = (request) => switch (request.url.host) {
            'proton.me' => http.Response('', 301,
                headers: {'location': 'https://account.proton.me/'}),
            'account.proton.me' => http.Response('', 200,
                headers: {'onion-location': 'https://$_proton/'}),
            _ => http.Response('', 404),
          };
      expect(await _check('https://proton.me/'), isA<OnionAnnounced>());

      net.responder = (_) => http.Response('', 302,
          headers: {'location': 'https://evil.example/'});
      expect(await _check('https://proton.me/'), isA<OnionCheckFailed>());
      expect(net.requested.map((u) => u.host), isNot(contains('evil.example')));
    });

    test('a redirect down to http is refused', () async {
      net.responder = (request) => request.url.scheme == 'https'
          ? http.Response('', 301, headers: {'location': 'http://proton.me/'})
          : http.Response('', 200,
              headers: {'onion-location': 'https://$_proton/'});
      expect(await _check('https://proton.me/'), isA<OnionCheckFailed>());
    });

    test('a plain-http answer announces nothing', () async {
      net.responder = (_) => http.Response('', 200,
          headers: {'onion-location': 'https://$_proton/'});
      expect(await _check('http://proton.me/'), isA<NothingAnnounced>());
    });

    test('a server error or a refused route keeps what was learned', () async {
      net.responder = (_) => http.Response('', 503);
      expect(await _check('https://proton.me/'), isA<OnionCheckFailed>());
      net.block = true;
      expect(await _check('https://proton.me/'), isA<OnionCheckFailed>());
    });
  });
}
