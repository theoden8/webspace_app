// LEAK-016 at the Dart seams: a request with no proxy never goes to an
// overlay network's name (an onion service, an I2P site), and nothing asks
// the device's resolver about one. Only the network's own router resolves the
// name, so a direct attempt reaches nothing and tells the resolver, and
// whoever runs it, which site is being opened.
//
// The refusals are asserted on real sockets: a direct attempt that got past
// them would fail too, but as a host lookup, which is the leak.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/download_engine.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/outbound_http_io.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

import '../integration_test/self_signed_cert.dart';

const _onion = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
const _i2p = 'ukeu3k5oycgaauneqgtnvselmt4yemvoilkln7jpvamvfx7dnkdq.b32.i2p';

/// One name of each overlay network, so a check that forgets one fails.
const _overlays = {OverlayNetwork.tor: _onion, OverlayNetwork.i2p: _i2p};

// package:http rewraps the factory's failure as its own SocketException, so
// the refusal is read by its words.
Matcher _refusedAs(OverlayNetwork overlay) => throwsA(isA<SocketException>()
    .having((e) => e.message, 'message', contains(overlay.what)));

// The refusal's own words: a direct attempt that got past it fails too, and
// its message carries the URL, name and all.
Matcher _downloadRefusedAs(OverlayNetwork overlay) => throwsA(isA<DownloadException>()
    .having((e) => e.message, 'message',
        contains('only through ${overlay.router} or a proxy')));

http.Client _direct() => (const DefaultOutboundHttpFactory()
        .clientFor(OutboundProxy.ofApp(UserProxySettings(type: ProxyType.DEFAULT)).resolved)
    as OutboundClientReady)
    .client;

/// A loopback server that answers every request with a redirect to [to].
Future<HttpServer> _redirectingTo(String to) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    req.response
      ..statusCode = HttpStatus.found
      ..headers.set(HttpHeaders.locationHeader, to);
    unawaited(req.response.close());
  });
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
  });

  test('Host.overlay reads the last label, normalized', () {
    expect(Host(_onion).overlay, OverlayNetwork.tor);
    expect(Host('Forum.ONION.').overlay, OverlayNetwork.tor);
    expect(Host('onion').overlay, OverlayNetwork.tor);
    expect(Host(_i2p).overlay, OverlayNetwork.i2p);
    expect(Host('Forum.I2P.').overlay, OverlayNetwork.i2p);
    expect(Host('i2p').overlay, OverlayNetwork.i2p);
    for (final clear in [
      'onion.example.com',
      'myonion',
      'example.onions',
      'i2p.example.com',
      'noti2p',
      'example.i2pd',
      'example.com',
    ]) {
      expect(Host(clear).overlay, isNull, reason: clear);
    }
  });

  group('the direct client (LEAK-016)', () {
    for (final MapEntry(key: overlay, value: name) in _overlays.entries) {
      test('refuses ${overlay.what} before anything resolves it', () async {
        await expectLater(_direct().get(Uri.parse('http://$name/')),
            _refusedAs(overlay));
        await expectLater(_direct().get(Uri.parse('https://www.$name/')),
            _refusedAs(overlay));
      });

      test('refuses a redirect to ${overlay.what}, on the hop', () async {
        final server = await _redirectingTo('http://$name/next');
        await expectLater(
            _direct().get(Uri.parse('http://127.0.0.1:${server.port}/')),
            _refusedAs(overlay));
      });
    }

    test('still reaches a clearnet host over http and https', () async {
      // The refusal sits in a connection factory that replaces dart:io's own
      // connect, so the ordinary paths are asserted here too.
      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      plain.listen((req) {
        req.response.write('plain');
        unawaited(req.response.close());
      });
      addTearDown(() => plain.close(force: true));
      expect(
          (await _direct().get(Uri.parse('http://127.0.0.1:${plain.port}/')))
              .body,
          'plain');

      final cert = generateSelfSignedCert(
        commonName: 'localhost',
        ipAddresses: ['127.0.0.1'],
      );
      final secure = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4, 0, cert.serverContext());
      secure.listen((req) {
        req.response.write('secure');
        unawaited(req.response.close());
      });
      addTearDown(() => secure.close(force: true));
      await TrustedHostsService.instance.trust(
        host: '127.0.0.1',
        port: secure.port,
        fingerprint: sha256.convert(cert.certDer).toString(),
      );
      addTearDown(() => TrustedHostsService.instance.clear());
      expect(
          (await _direct().get(Uri.parse('https://127.0.0.1:${secure.port}/')))
              .body,
          'secure');
    });
  });

  group('the device resolver (LEAK-016)', () {
    final asked = <String>[];

    setUp(() {
      asked.clear();
      hostLookup = (host) async {
        asked.add(host);
        return ['93.184.216.34'];
      };
    });

    tearDown(resetHostLookup);

    test('is never asked about an overlay name', () async {
      for (final name in _overlays.values) {
        expect(await classifyResolvedHost(name), HostRangeVerdict.unresolvable);
        expect(
            await classifyOutboundTarget('http://$name/x',
                effective: UserProxySettings(type: ProxyType.DEFAULT)),
            HostRangeVerdict.unresolvable);
      }
      expect(asked, isEmpty);
    });

    test('is still asked about a clearnet name', () async {
      expect(await classifyResolvedHost('example.com'),
          HostRangeVerdict.public);
      expect(asked, ['example.com']);
    });
  });

  group('downloads (LEAK-016)', () {
    for (final MapEntry(key: overlay, value: name) in _overlays.entries) {
      test('a direct download from ${overlay.what} is refused before it '
          'starts', () async {
        final engine = DownloadEngine(
            proxy: OutboundProxy.ofSite(
                UserProxySettings(type: ProxyType.DEFAULT),
                site: SiteId('test-site')));
        await expectLater(
          engine.fetch(url: 'http://$name/file.zip'),
          _downloadRefusedAs(overlay),
        );
      });

      test('so is a redirect to ${overlay.what}', () async {
        final server = await _redirectingTo('http://$name/file.zip');
        final engine = DownloadEngine(proxy: OutboundProxy.app);
        await expectLater(
          engine.fetch(url: 'http://127.0.0.1:${server.port}/start'),
          _downloadRefusedAs(overlay),
        );
      });
    }

    test('a client the caller routes is the caller\'s to judge', () async {
      final engine = DownloadEngine(
          client: MockClient((_) async => http.Response('bytes', 200)), proxy: OutboundProxy.app);
      final result = await engine.fetch(url: 'http://$_onion/file.zip');
      expect(result.bytes, isNotEmpty);
    });
  });
}
