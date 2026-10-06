// PROXY-019: the connection-test control. The service decides what happened;
// this is about the tile saying so, and not running two tests at once.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';
import 'helpers/fake_outbound.dart';
import 'helpers/localized.dart';

Widget _host(UserProxySettings Function() settings) => localizedApp(Scaffold(
  body: ProxyTestTile(
    settings: settings,
    target: Uri.parse('https://example.org/'),
  ),
));

UserProxySettings _socks5({String? username, String? password}) =>
    UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '127.0.0.1:1080',
      username: username,
      password: password,
    );

void main() {
  tearDown(resetOutboundHttp);

  testWidgets('a working proxy reports the host and status it reached',
      (tester) async {
    outboundHttp = FakeOutbound(responder: (_) => http.Response('ok', 200));

    await tester.pumpWidget(_host(_socks5));
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('The proxy works'), findsOneWidget);
    expect(find.text('HTTP 200 - example.org'), findsOneWidget);
  });

  testWidgets('a rejected credential is named as such, not as unreachable',
      (tester) async {
    outboundHttp = FakeOutbound(responder: (_) => http.Response('ok', 407));

    await tester.pumpWidget(_host(() => _socks5(username: 'u', password: 'bad')));
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('The proxy rejected these credentials'), findsOneWidget);
  });

  testWidgets('a blocked seam reports the reason it was blocked',
      (tester) async {
    outboundHttp = FakeOutbound(
        blockWhen: (_) => true, blockReason: 'Tor is not bootstrapped yet.');

    await tester.pumpWidget(_host(() => UserProxySettings(type: ProxyType.TOR)));
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('Could not reach the proxy'), findsOneWidget);
    expect(find.text('Tor is not bootstrapped yet.'), findsOneWidget);
  });

  testWidgets('a second tap while one test is in flight starts nothing',
      (tester) async {
    final gate = Completer<http.Response>();
    final factory = FakeOutbound(responder: (_) => gate.future);
    outboundHttp = factory;

    await tester.pumpWidget(_host(_socks5));
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Test connection'), warnIfMissed: false);
    await tester.pump();
    expect(factory.queries, hasLength(1));

    gate.complete(http.Response('ok', 200));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the test uses what the form holds now, not what it held at build',
      (tester) async {
    var address = 'first.example:1080';
    final factory = FakeOutbound(responder: (_) => http.Response('ok', 200));
    outboundHttp = factory;

    await tester.pumpWidget(_host(() => UserProxySettings(
          type: ProxyType.SOCKS5,
          address: address,
        )));
    address = 'second.example:1080';
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(factory.lastQuery!.address, 'second.example:1080');
  });
}
