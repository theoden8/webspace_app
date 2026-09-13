// PROXY-019: the connection test reports what actually happened, and the
// probe target never silently sidesteps the proxy.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Models the seam rather than stubbing it: the real factory hands back a
/// sealed result and the caller must cope with both arms, so a fake that
/// only ever returns a client would test half the contract.
class _FakeFactory implements OutboundHttpFactory {
  _FakeFactory(this._build);

  final OutboundClient Function(UserProxySettings) _build;
  UserProxySettings? lastRequested;

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    lastRequested = settings;
    return _build(settings);
  }
}

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
      outboundHttp = _FakeFactory((_) {
        client = _ScriptedClient((_) async => _response(204));
        return OutboundClientReady(client);
      });

      final result = await testProxyConnection(_socks5(), target: target);

      expect(result.outcome, ProxyTestOutcome.reachable);
      expect(result.statusCode, 204);
      expect(client.closed, isTrue, reason: 'the probe client must be closed');
    });

    test('a 407 is an auth rejection, not a reachable proxy', () async {
      outboundHttp = _FakeFactory(
          (_) => OutboundClientReady(_ScriptedClient((_) async => _response(407))));

      final result = await testProxyConnection(
        _socks5(username: 'u', password: 'wrong'),
        target: target,
      );

      expect(result.outcome, ProxyTestOutcome.authRejected);
      expect(result.statusCode, 407);
    });

    test('a refused tunnel carrying 407 in its message is an auth rejection',
        () async {
      outboundHttp = _FakeFactory((_) => OutboundClientReady(
            _ScriptedClient((_) async => throw http.ClientException(
                'Proxy failed to establish tunnel '
                '(407 Proxy Authentication Required)')),
          ));

      final result = await testProxyConnection(
        _socks5(username: 'u', password: 'wrong'),
        target: target,
      );

      expect(result.outcome, ProxyTestOutcome.authRejected);
      expect(result.detail, contains('407'));
    });

    test('a SOCKS5 authentication failure is an auth rejection', () async {
      outboundHttp = _FakeFactory((_) => OutboundClientReady(
            _ScriptedClient(
                (_) async => throw StateError('SOCKS5 authentication failed')),
          ));

      final result = await testProxyConnection(
        _socks5(username: 'u', password: 'wrong'),
        target: target,
      );

      expect(result.outcome, ProxyTestOutcome.authRejected);
    });

    test('a connection error is unreachable and keeps the underlying text',
        () async {
      outboundHttp = _FakeFactory((_) => OutboundClientReady(
            _ScriptedClient((_) async =>
                throw http.ClientException('Connection refused')),
          ));

      final result = await testProxyConnection(_socks5(), target: target);

      expect(result.outcome, ProxyTestOutcome.unreachable);
      expect(result.detail, contains('Connection refused'));
    });

    test('no answer before the deadline times out', () async {
      outboundHttp = _FakeFactory((_) => OutboundClientReady(
            _ScriptedClient((_) => Completer<http.StreamedResponse>().future),
          ));

      final result = await testProxyConnection(
        _socks5(),
        target: target,
        timeout: const Duration(milliseconds: 20),
      );

      expect(result.outcome, ProxyTestOutcome.timedOut);
    });

    test('a blocked seam is reported, never retried without the proxy',
        () async {
      final factory = _FakeFactory(
          (_) => const OutboundClientBlocked('Tor is not bootstrapped yet.'));
      outboundHttp = factory;

      final result = await testProxyConnection(
        UserProxySettings(type: ProxyType.TOR),
        target: target,
        siteId: 'site-1',
      );

      expect(result.outcome, ProxyTestOutcome.blocked);
      expect(result.detail, contains('Tor'));
    });

    test('a per-site TOR test rides the site\'s own isolation tag (PROXY-011)',
        () async {
      final factory = _FakeFactory(
          (_) => const OutboundClientBlocked('not bootstrapped'));
      outboundHttp = factory;

      await testProxyConnection(
        UserProxySettings(type: ProxyType.TOR),
        target: target,
        siteId: 'site-42',
      );

      expect(factory.lastRequested!.username, 'site-42');
    });

    test('DEFAULT falls through to the app-wide proxy (PROXY-009)', () async {
      GlobalOutboundProxy.setForTest(UserProxySettings(
        type: ProxyType.HTTP,
        address: 'global.example:3128',
      ));
      addTearDown(() =>
          GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.DEFAULT)));
      final factory = _FakeFactory(
          (_) => OutboundClientReady(_ScriptedClient((_) async => _response(200))));
      outboundHttp = factory;

      await testProxyConnection(
        UserProxySettings(type: ProxyType.DEFAULT),
        target: target,
      );

      expect(factory.lastRequested!.type, ProxyType.HTTP);
      expect(factory.lastRequested!.address, 'global.example:3128');
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
