import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/network_sign_in.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/webview_tls.dart';

import 'helpers/capture_fakes.dart';
import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';

/// A self-signed certificate as the platform hands it over, [der] standing
/// in for its bytes, which only the fingerprint reads.
inapp.SslCertificate _cert({List<int>? der = const [7, 7, 7]}) =>
    inapp.SslCertificate(
      issuedTo: inapp.SslCertificateDName(CName: 'self-signed.example'),
      issuedBy: inapp.SslCertificateDName(CName: 'self-signed.example'),
      x509Certificate: der == null
          ? null
          : (inapp.X509Certificate()..encoded = Uint8List.fromList(der)),
    );

inapp.ServerTrustChallenge _challenge(
  String host, {
  required inapp.SslCertificate cert,
}) => inapp.ServerTrustChallenge(
  protectionSpace: inapp.URLProtectionSpace(
    host: host,
    protocol: 'https',
    port: 443,
    sslCertificate: cert,
  ),
);

/// The host's answers, recording which hosts the user was asked about.
class _Host {
  _Host({required this.trust});

  final bool trust;
  final asked = <String>[];

  WebViewHostHooks get hooks => WebViewHostHooks(
    isolation: fakeSharedJar,
    globalUserScripts: () => const [],
    save: () async {},
    rebuild: () {},
    launchNested: (_, {required posture, homeTitle}) {},
    openInBrowser: (_) async => false,
    openSiteSettings: (_) {},
    showPopup: (_, {required url, required kind}) async {},
    externalScheme: (_, {required loadIn}) async {},
    confirmScriptFetch: (_) async => false,
    untrustedCertificate: (host, {required port, required certificate}) async {
      asked.add(host);
      return trust;
    },
    networkSignIn: (_) async {},
    httpAuth: (_) async => null,
    media: FakePrompter(),
  );
}

const _host = 'self-signed.example';
const _url = 'https://self-signed.example/';

bool _pinned(inapp.SslCertificate cert) => TrustedHostsService.instance
    .isTrusted(
      host: _host,
      port: 443,
      fingerprint: TrustedHostsService.fingerprintFromInappCertificate(cert),
    );

/// The trust prompt on the paths each platform reports a rejected
/// certificate through: the trust callback (`handleServerTrust`), which
/// Android and Linux fire only once the OS rejected the chain and iOS and
/// macOS fire for every handshake, and the failed load (`handleSslLoadError`).
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await TrustedHostsService.instance.clear();
    WebViewTls.resetForTest();
    NetworkSignIn.instance =
        NetworkSignIn(read: () async => const NoSignIn());
  });

  test('TLS-001, TLS-009: on iOS and macOS the OS decides every certificate: '
      'no prompt, no pin, no reload', () async {
    final host = _Host(trust: true);
    final view = FakeWebViewController();
    final response = await WebViewTls.handleServerTrust(
      view,
      challenge: _challenge(_host, cert: _cert()),
      hooks: host.hooks,
      apple: true,
    );
    expect(response, isNull,
        reason: 'null is the plugin answer that defers to the OS');
    expect(
      await WebViewTls.handleSslLoadError(
        view: view,
        url: _url,
        hooks: host.hooks,
        apple: true,
      ),
      isFalse,
      reason: 'the load fails with the OS error',
    );
    await pumpEventQueue();
    expect(host.asked, isEmpty);
    expect(_pinned(_cert()), isFalse);
    expect(view.calls, isEmpty);
  });

  test('TLS-002: a rejected certificate on Android or Linux is asked about, '
      'pinned, and the page reloaded once', () async {
    final host = _Host(trust: true);
    final view = FakeWebViewController();
    final response = await WebViewTls.handleServerTrust(
      view,
      challenge: _challenge(_host, cert: _cert()),
      hooks: host.hooks,
      apple: false,
    );
    expect(response?.action, inapp.ServerTrustAuthResponseAction.PROCEED);
    expect(host.asked, [_host]);
    expect(_pinned(_cert()), isTrue);
    await pumpEventQueue();
    expect(view.calls, ['reload']);
  });

  test('TLS-003: a stale load error for a host already pinned reloads once and '
      'asks nothing', () async {
    final host = _Host(trust: true);
    final view = FakeWebViewController();
    // The trust callback saw the certificate, which the failed load does not
    // carry, and the user pinned it.
    await WebViewTls.handleServerTrust(
      null,
      challenge: _challenge(_host, cert: _cert()),
      hooks: null,
      apple: true,
    );
    await TrustedHostsService.instance.trust(
      host: _host,
      port: 443,
      fingerprint: TrustedHostsService.fingerprintFromInappCertificate(_cert())!,
    );
    for (var i = 0; i < 2; i++) {
      expect(
        await WebViewTls.handleSslLoadError(
          view: view,
          url: _url,
          hooks: host.hooks,
          apple: false,
        ),
        isTrue,
      );
    }
    await pumpEventQueue();
    expect(host.asked, isEmpty);
    expect(view.calls, ['loadUrl $_url'],
        reason: 'one reload a failure burst, not one an error');
  });

  group('TLS-006: a certificate whose bytes the platform did not give', () {
    test('has no fingerprint', () {
      expect(TrustedHostsService.fingerprintFromInappCertificate(null), isNull);
      expect(
        TrustedHostsService.fingerprintFromInappCertificate(_cert(der: null)),
        isNull,
      );
      expect(
        TrustedHostsService.fingerprintFromInappCertificate(_cert(der: [])),
        isNull,
      );
    });

    test('is let through once approved, and pinned for no host', () async {
      final host = _Host(trust: true);
      for (final der in [null, <int>[]]) {
        final response = await WebViewTls.handleServerTrust(
          null,
          challenge: _challenge(_host, cert: _cert(der: der)),
          hooks: host.hooks,
          apple: false,
        );
        expect(response?.action, inapp.ServerTrustAuthResponseAction.PROCEED);
        WebViewTls.resetForTest();
      }
      expect(TrustedHostsService.instance.all(), isEmpty);
    });
  });

  group('TLS-008: the pins the first prompt release left', () {
    test('are cleared on the first launch after it, and only then', () async {
      final loaded = await TrustedHostsService.instance.initialize();
      await TrustedHostsService.instance
          .trust(host: 'github.com', port: 443, fingerprint: 'aa');
      await loaded.resetOnceForOsDefault();
      expect(TrustedHostsService.instance.all(), isEmpty);

      await TrustedHostsService.instance
          .trust(host: _host, port: 443, fingerprint: 'bb');
      await loaded.resetOnceForOsDefault();
      expect([for (final e in TrustedHostsService.instance.all()) e.host],
          [_host], reason: 'a pin approved since is kept');
    });
  });
}
