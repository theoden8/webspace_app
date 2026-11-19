import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/onion_location.dart';
import 'package:webspace/services/site_origins.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_field.dart';
import 'package:webspace/web_view_model.dart';

const _proton =
    'protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion';
const _torProject =
    '2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion';
const _ddg = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
const _dw = 'www.dwnewsgngmhlplxy6o2twtfgjnrnjxbegbwqx6wnotdhkzt562tszfid.onion';

/// [address] with the character at [index] swapped for another base32 one.
String _changed(String address, {required int index}) {
  final c = address[index] == 'a' ? 'b' : 'a';
  return address.replaceRange(index, index + 1, c);
}

void main() {
  group('OnionAddress (ONION-002)', () {
    test('real v3 addresses check', () {
      for (final host in [_proton, _torProject, _ddg, _dw]) {
        expect(OnionAddress.ofHost(Host(host)), isNotNull, reason: host);
      }
    });

    test('a subdomain names the same service', () {
      expect(OnionAddress.ofHost(Host(_dw)),
          OnionAddress.ofHost(Host(_dw.substring(4))));
    });

    test('one changed character in the key or the checksum is refused', () {
      for (final index in [0, 10, 50, 51, 52, 53]) {
        final changed = _changed(_proton, index: index);
        expect(OnionAddress.ofHost(Host(changed)), isNull, reason: changed);
      }
    });

    test('a changed version byte is refused', () {
      expect(OnionAddress.ofHost(Host(_changed(_proton, index: 55))), isNull);
    });

    test('a v2 address, a clearnet host and a bare label are refused', () {
      for (final host in ['expyuzz4wqqyqhjn.onion', 'proton.me', 'onion',
          'protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd']) {
        expect(OnionAddress.ofHost(Host(host)), isNull, reason: host);
      }
    });
  });

  group('announcedEndpoint', () {
    final home = Uri.parse('https://proton.me/mail');

    test('the header names the endpoint', () {
      final endpoint = announcedEndpoint(
          answeredBy: home, header: 'https://$_proton/', document: '');
      expect(endpoint?.from, 'https://proton.me');
      expect(endpoint?.to, 'https://$_proton');
    });

    test('the meta tag counts when no header is sent', () {
      final endpoint = announcedEndpoint(
          answeredBy: home,
          header: null,
          document: '<html><head><title>x</title>'
              "<meta content='http://$_torProject/index.html' "
              'HTTP-EQUIV="Onion-Location"></head><body></body></html>');
      expect(endpoint?.to, 'http://$_torProject');
    });

    test('the header wins over the meta tag', () {
      final endpoint = announcedEndpoint(
          answeredBy: home,
          header: 'https://$_proton/',
          document: '<head><meta http-equiv="onion-location" '
              'content="http://$_torProject/"></head>');
      expect(endpoint?.to, 'https://$_proton');
    });

    test('a meta tag in the body does not count', () {
      expect(
          announcedEndpoint(
              answeredBy: home,
              header: null,
              document: '<head></head><body><meta http-equiv="onion-location" '
                  'content="https://$_proton/"></body>'),
          isNull);
    });

    test('a plain-http answer is not trusted', () {
      expect(
          announcedEndpoint(
              answeredBy: Uri.parse('http://proton.me/'),
              header: 'https://$_proton/',
              document: ''),
          isNull);
    });

    test('a malformed or non-onion announcement is ignored (ONION-002)', () {
      for (final value in [
        'https://${_changed(_proton, index: 3)}/',
        'https://evil.example/',
        'ftp://$_proton/',
        'https://$_proton:8443/',
        'not a url',
      ]) {
        expect(
            announcedEndpoint(answeredBy: home, header: value, document: ''),
            isNull,
            reason: value);
      }
    });
  });

  group('OnionEndpoint.rewrite', () {
    final endpoint =
        OnionEndpoint.of(from: 'https://proton.me', to: 'https://$_proton/')!;

    test('the announcing origin moves to the onion, path kept', () {
      expect(endpoint.rewrite('https://proton.me/mail?x=1#top'),
          'https://$_proton/mail?x=1#top');
      expect(endpoint.rewrite('https://PROTON.me:443/'), 'https://$_proton/');
    });

    test('another host, scheme or port is left alone', () {
      for (final url in [
        'https://account.proton.me/login',
        'http://proton.me/',
        'https://proton.me:8443/',
        'https://$_proton/',
      ]) {
        expect(endpoint.rewrite(url), isNull, reason: url);
      }
    });

    test('an http onion for an https site keeps the onion scheme', () {
      final tor = OnionEndpoint.of(
          from: 'https://www.torproject.org', to: 'http://$_torProject/')!;
      expect(tor.rewrite('https://www.torproject.org/download/'),
          'http://$_torProject/download/');
    });
  });

  group('SiteOnion', () {
    final endpoint =
        OnionEndpoint.of(from: 'https://proton.me', to: 'https://$_proton/')!;
    SiteOnion learned(OnionAnswer? answer) => SiteOnion(
        endpoint: endpoint, checked: DateTime.utc(2026, 11, 19), answer: answer);

    test('only an accepted address is used', () {
      expect(learned(null).endpointOn(tor: true), isNull);
      expect(learned(OnionAnswer.declined).endpointOn(tor: true), isNull);
      expect(learned(OnionAnswer.accepted).endpointOn(tor: true), endpoint);
    });

    test('off Tor the endpoint is not used and a saved onion URL '
        'starts on the clearnet origin', () {
      final accepted = learned(OnionAnswer.accepted);
      expect(accepted.endpointOn(tor: false), isNull);
      expect(accepted.startUrl('https://$_proton/mail', inUse: null),
          'https://proton.me/mail');
      expect(accepted.startUrl('https://$_proton/mail', inUse: endpoint),
          'https://$_proton/mail');
      expect(accepted.startUrl('https://proton.me/mail', inUse: null),
          'https://proton.me/mail');
    });

    test('saved and read back; a wrong shape reads as absent', () {
      for (final answer in [null, ...OnionAnswer.values]) {
        final back = SiteOnion.fromJson(learned(answer).toJson());
        expect(back?.endpoint, endpoint);
        expect(back?.answer, answer);
        expect(back?.checked, DateTime.utc(2026, 11, 19));
      }
      for (final json in [
        null,
        'x',
        {'from': 'https://proton.me', 'to': 1, 'checked': '2026-11-19'},
        {'from': 'https://proton.me', 'to': 'https://proton.me',
            'checked': '2026-11-19'},
        {'from': 'https://proton.me', 'to': 'https://$_proton',
            'checked': 'yesterday'},
      ]) {
        expect(SiteOnion.fromJson(json), isNull, reason: '$json');
      }
    });

    test('a site saves it, and neither a backup nor a QR carries it',
        () {
      final site = WebViewModel(initUrl: 'https://proton.me/mail')
        ..onionLocation = learned(OnionAnswer.accepted);
      final json = site.toJson();
      expect(json[SiteField.onionLocation.key], isNotNull);
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.onionLocation?.endpoint, endpoint);
      expect(SiteField.onionLocation.backup, BackupShare.withheld);
      expect(SiteField.onionLocation.qr, QrShare.withheld);
    });

    test('the model resolves the endpoint only on a Tor route', () {
      final direct = WebViewModel(initUrl: 'https://proton.me/')
        ..onionLocation = learned(OnionAnswer.accepted);
      expect(direct.onionEndpoint, isNull);
      final tor = WebViewModel(
          initUrl: 'https://proton.me/',
          proxySettings: UserProxySettings(type: ProxyType.TOR))
        ..onionLocation = learned(OnionAnswer.accepted);
      expect(tor.onionEndpoint, endpoint);
    });
  });

  group('the onion origin as the site\'s own (ONION-005)', () {
    final endpoint =
        OnionEndpoint.of(from: 'https://www.torproject.org',
            to: 'http://$_torProject/')!;
    const home = 'https://www.torproject.org/';

    test('SiteOrigins owns it on its own scheme while it is the endpoint', () {
      final on = SiteOrigins(home,
          claims: DomainClaim.implicitFor(home), onion: endpoint);
      final off = SiteOrigins(home,
          claims: DomainClaim.implicitFor(home), onion: null);
      expect(on.owns('http://$_torProject'), isTrue);
      expect(on.owns('https://$_torProject'), isFalse);
      expect(off.owns('http://$_torProject'), isFalse);
      expect(on.owns('https://www.torproject.org'), isTrue);
    });

    test('a navigation inside the onion stays in the site\'s webview', () {
      NavigationDecision decide(OnionEndpoint? onion) =>
          NavigationDecisionEngine.decideShouldOverrideUrlLoading(
            targetUrl: 'http://$_torProject/download/',
            initUrl: home,
            boundary: NavigationBoundary(
                homeUrl: home, initialUrl: home, onion: onion),
            frame: NavigationFrame.top,
            hasGesture: true,
            isSiteActive: true,
            lastSameDomainGestureTime: null,
            now: DateTime.utc(2026, 11, 19),
            externalLinkMode: ExternalLinkMode.inApp,
          ).decision;
      expect(decide(endpoint), NavigationDecision.allow);
      expect(decide(null), isNot(NavigationDecision.allow));
    });
  });
}
