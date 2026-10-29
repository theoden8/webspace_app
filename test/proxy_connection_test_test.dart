// PROXY-019: the connection test reports what actually happened, and the
// probe target never silently sidesteps the proxy.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'helpers/fake_outbound.dart';

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _respond;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _respond(request);

  @override
  void close() => closed = true;
}

http.StreamedResponse _response(int status) => http.StreamedResponse(
      Stream<List<int>>.fromIterable([
        [104, 105]
      ]),
      status,
    );

UserProxySettings _socks5({String? username, String? password}) =>
    UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '127.0.0.1:1080',
      username: username,
      password: password,
    );

void main() {
  final target = Uri.parse('https://example.org/');

  tearDown(resetOutboundHttp);

  group('testProxyConnection', () {
    test('a response through the proxy is reachable, and carries its status',
        () async {
      late _ScriptedClient client;
      outboundHttp = FakeOutbound(
          client: () => client = _ScriptedClient((_) async => _response(204)));

      final result = await testProxyConnection(
        OutboundProxy.ofApp(_socks5()),
        target: target,
        holdTor: null,
      );

      expect(result.outcome, ProxyTestOutcome.reachable);
      expect(result.statusCode, 204);
      expect(client.closed, isTrue, reason: 'the probe client must be closed');
    });

    test('a 407 is an auth rejection, not a reachable proxy', () async {
      outboundHttp = FakeOutbound(
          client: () => _ScriptedClient((_) async => _response(407)));

      final result = await testProxyConnection(
        OutboundProxy.ofApp(_socks5(username: 'u', password: 'wrong')),
        target: target,
        holdTor: null,
      );

      expect(result.outcome, ProxyTestOutcome.authRejected);
      expect(result.statusCode, 407);
    });

    test('a refused tunnel carrying 407 in its message is an auth rejection',
        () async {
      outboundHttp = FakeOutbound(
          client: () => _ScriptedClient((_) async => throw http.ClientException(
              'Proxy failed to establish tunnel '
              '(407 Proxy Authentication Required)')));

      final result = await testProxyConnection(
        OutboundProxy.ofApp(_socks5(username: 'u', password: 'wrong')),
        target: target,
        holdTor: null,
      );

      expect(result.outcome, ProxyTestOutcome.authRejected);
      expect(result.detail, contains('407'));
    });

    test('a SOCKS5 authentication failure is an auth rejection', () async {
      outboundHttp = FakeOutbound(
          client: () => _ScriptedClient(
              (_) async => throw const SocksHandshakeFailure(
                  'Exception: Authentication failed.')));

      final result = await testProxyConnection(
        OutboundProxy.ofApp(_socks5(username: 'u', password: 'wrong')),
        target: target,
        holdTor: null,
      );

      expect(result.outcome, ProxyTestOutcome.authRejected);
    });

    test('a connection error is unreachable and keeps the underlying text',
        () async {
      outboundHttp = FakeOutbound(
          client: () => _ScriptedClient(
              (_) async => throw http.ClientException('Connection refused')));

      final result = await testProxyConnection(
        OutboundProxy.ofApp(_socks5()),
        target: target,
        holdTor: null,
      );

      expect(result.outcome, ProxyTestOutcome.unreachable);
      expect(result.detail, contains('Connection refused'));
    });

    test('no answer before the deadline times out', () async {
      outboundHttp = FakeOutbound(
          client: () => _ScriptedClient(
              (_) => Completer<http.StreamedResponse>().future));

      final result = await testProxyConnection(
        OutboundProxy.ofApp(_socks5()),
        target: target,
        holdTor: null,
        timeout: const Duration(milliseconds: 20),
      );

      expect(result.outcome, ProxyTestOutcome.timedOut);
    });

    test('a blocked seam is reported, never retried without the proxy',
        () async {
      final factory = FakeOutbound(
          blockWhen: (_) => true, blockReason: 'Tor is not bootstrapped yet.');
      outboundHttp = factory;

      final result = await testProxyConnection(
        OutboundProxy.ofSite(UserProxySettings(type: ProxyType.TOR), site: SiteId('site-1')),
        target: target,
        holdTor: null,
      );

      expect(result.outcome, ProxyTestOutcome.blocked);
      expect(result.detail, contains('Tor'));
    });

    test('a per-site TOR test rides the site\'s own isolation tag (PROXY-011)',
        () async {
      final factory = FakeOutbound(blockWhen: (_) => true);
      outboundHttp = factory;

      await testProxyConnection(
        OutboundProxy.ofSite(UserProxySettings(type: ProxyType.TOR), site: SiteId('site-42')),
        target: target,
        holdTor: null,
      );

      expect(factory.lastQuery!.username, 'site-42');
    });

    test('a Tor route is probed with Tor held, any other route without it',
        () async {
      final factory = FakeOutbound(blockWhen: (_) => true);
      outboundHttp = factory;
      final holds = <Duration>[];
      Future<ProxyTestResult> hold({
        required Duration within,
        required Future<ProxyTestResult> Function() probe,
      }) async {
        holds.add(within);
        expect(factory.queries, isEmpty, reason: 'probed inside the hold');
        return probe();
      }

      await testProxyConnection(
        OutboundProxy.ofSite(UserProxySettings(type: ProxyType.TOR), site: SiteId('site-1')),
        target: target,
        holdTor: hold,
        timeout: const Duration(seconds: 7),
      );
      expect(holds, [const Duration(seconds: 7)]);
      expect(factory.queries.single.type, ProxyType.TOR);

      await testProxyConnection(
        OutboundProxy.ofApp(_socks5()),
        target: target,
        holdTor: hold,
      );
      expect(holds, hasLength(1), reason: 'SOCKS5 starts no Tor');
    });

    test('a DEFAULT site under an app-wide Tor holds Tor too', () async {
      GlobalOutboundProxy.setInMemory(UserProxySettings(type: ProxyType.TOR));
      addTearDown(GlobalOutboundProxy.resetForTest);
      outboundHttp = FakeOutbound(blockWhen: (_) => true);
      var held = false;

      await testProxyConnection(
        OutboundProxy.ofApp(UserProxySettings(type: ProxyType.DEFAULT)),
        target: target,
        holdTor: ({required within, required probe}) {
          held = true;
          return probe();
        },
      );
      expect(held, isTrue);
    });

    test('DEFAULT falls through to the app-wide proxy (PROXY-009)', () async {
      GlobalOutboundProxy.setInMemory(UserProxySettings(
        type: ProxyType.HTTP,
        address: 'global.example:3128',
      ));
      addTearDown(() =>
          GlobalOutboundProxy.setInMemory(UserProxySettings(type: ProxyType.DEFAULT)));
      final factory = FakeOutbound(
          client: () => _ScriptedClient((_) async => _response(200)));
      outboundHttp = factory;

      await testProxyConnection(
        OutboundProxy.ofApp(UserProxySettings(type: ProxyType.DEFAULT)),
        target: target,
        holdTor: null,
      );

      expect(factory.lastQuery!.type, ProxyType.HTTP);
      expect(factory.lastQuery!.address, 'global.example:3128');
    });
  });

  group('proxyTestTarget', () {
    test('uses the site origin, without its path or query', () {
      expect(
        proxyTestTarget('https://site.example/app/page?token=secret'),
        Uri.parse('https://site.example/'),
      );
    });

    test('falls back for a loopback or private site, which bypasses the proxy',
        () {
      // PROXY-007 exempts these from the proxy, so a test against one would
      // come back green without a byte having crossed it.
      expect(proxyTestTarget('http://localhost:3000/'), kDefaultProxyTestTarget);
      expect(proxyTestTarget('http://127.0.0.1:8080/'), kDefaultProxyTestTarget);
      expect(proxyTestTarget('http://192.168.1.4/'), kDefaultProxyTestTarget);
    });

    test('falls back for anything that is not an http(s) URL', () {
      expect(proxyTestTarget(null), kDefaultProxyTestTarget);
      expect(proxyTestTarget(''), kDefaultProxyTestTarget);
      expect(proxyTestTarget('file:///tmp/page.html'), kDefaultProxyTestTarget);
      expect(proxyTestTarget('about:blank'), kDefaultProxyTestTarget);
    });
  });
}
