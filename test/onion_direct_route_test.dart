// LEAK-016 at the Dart seams: a request with no proxy never goes to an onion
// service, and nothing asks the device's resolver about one. Only Tor
// resolves the name, so a direct attempt reaches nothing and tells the
// resolver, and whoever runs it, which onion service is being opened.
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

final _refusedAsOnion = throwsA(isA<SocketException>()
    .having((e) => e.message, 'message', contains('onion service')));

// The refusal's own words: a direct attempt that got past it fails too, and
// its message carries the URL, onion and all.
final _downloadRefusedAsOnion = throwsA(isA<DownloadException>().having(
    (e) => e.message, 'message', contains('only through Tor or a proxy')));

http.Client _direct() => (const DefaultOutboundHttpFactory()
        .clientFor(UserProxySettings(type: ProxyType.DEFAULT))
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

  test('Host.isOnion is RFC 7686\'s name, normalized', () {
    expect(Host(_onion).isOnion, isTrue);
    expect(Host('Forum.ONION.').isOnion, isTrue);
    expect(Host('onion').isOnion, isTrue);
    expect(Host('onion.example.com').isOnion, isFalse);
    expect(Host('myonion').isOnion, isFalse);
    expect(Host('example.onions').isOnion, isFalse);
  });

  group('the direct client (LEAK-016)', () {
    test('refuses an onion service before anything resolves it', () async {
      await expectLater(_direct().get(Uri.parse('http://$_onion/')),
          _refusedAsOnion);
      await expectLater(_direct().get(Uri.parse('https://www.$_onion/')),
          _refusedAsOnion);
    });

    test('refuses a redirect to one, on the hop', () async {
      final server = await _redirectingTo('http://$_onion/next');
      await expectLater(
          _direct().get(Uri.parse('http://127.0.0.1:${server.port}/')),
          _refusedAsOnion);
    });

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

    test('is never asked about an onion name', () async {
      expect(await classifyResolvedHost(_onion), HostRangeVerdict.unresolvable);
      expect(
          await classifyOutboundTarget('http://$_onion/x',
              effective: UserProxySettings(type: ProxyType.DEFAULT)),
          HostRangeVerdict.unresolvable);
      expect(asked, isEmpty);
    });

    test('is still asked about a clearnet name', () async {
      expect(await classifyResolvedHost('example.com'),
          HostRangeVerdict.public);
      expect(asked, ['example.com']);
    });
  });

  group('downloads (LEAK-016)', () {
    test('a direct download of an onion URL is refused before it starts',
        () async {
      final engine =
          DownloadEngine(proxy: OutboundProxy.ofSite(UserProxySettings(type: ProxyType.DEFAULT), site: SiteId('test-site')));
      await expectLater(
        engine.fetch(url: 'http://$_onion/file.zip'),
        _downloadRefusedAsOnion,
      );
    });

    test('so is a redirect to one', () async {
      final server = await _redirectingTo('http://$_onion/file.zip');
      final engine = DownloadEngine(proxy: OutboundProxy.app);
      await expectLater(
        engine.fetch(url: 'http://127.0.0.1:${server.port}/start'),
        _downloadRefusedAsOnion,
      );
    });

    test('a client the caller routes is the caller\'s to judge', () async {
      final engine = DownloadEngine(
          client: MockClient((_) async => http.Response('bytes', 200)), proxy: OutboundProxy.app);
      final result = await engine.fetch(url: 'http://$_onion/file.zip');
      expect(result.bytes, isNotEmpty);
    });
  });
}
