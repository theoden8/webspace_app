import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/outbound_http_io.dart'
    show DefaultOutboundHttpFactory;
import 'package:webspace/settings/proxy.dart';

import '../integration_test/socks5_fixture.dart';

void main() {
  // No TestWidgetsFlutterBinding: it installs an HttpOverrides that answers
  // every HttpClient request 400 with an empty body, so a fetch through a
  // real SOCKS5 fixture reads nothing (the run that first had IPv6 did).
  //
  // The socket takes ProxyAddress.socketHost; the written host, brackets
  // kept, resolves nowhere, so the fetch failed where the native relay,
  // which already took socketHost, carried it.
  test('a SOCKS5 proxy written as a bracketed IPv6 literal carries a fetch '
      '(PROXY-017)', () async {
    final Socks5Fixture socks;
    try {
      socks = await Socks5Fixture.bind(on: InternetAddress.loopbackIPv6);
    } on SocketException {
      // CI's runners have ::1; a sandbox without it may skip, CI may not.
      if (Platform.environment['CI'] == 'true') rethrow;
      markTestSkipped('no IPv6 loopback on this machine');
      return;
    }
    addTearDown(socks.close);
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) {
      request.response.write('ok');
      unawaited(request.response.close());
    });
    final client = (const DefaultOutboundHttpFactory().clientFor(
      OutboundProxy.ofApp(UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '[::1]:${socks.port}',
      )).resolved,
    ) as OutboundClientReady)
        .client;
    addTearDown(client.close);
    final res = await client
        .get(Uri.parse('http://127.0.0.1:${origin.port}/'))
        .timeout(const Duration(seconds: 5));
    expect(res.body, 'ok');
    expect(socks.targets, ['127.0.0.1:${origin.port}']);
  });
}
