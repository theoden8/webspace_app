import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/main.dart' show getPageTitle;
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// LEAK-002 regression: `getPageTitle` used a raw `http.get`, so the
/// add-site / shortcut / inbound-link title probe reached the network
/// directly. `_executeCreateSite` runs it on a URL that arrived in a share
/// intent, which makes it an attacker-chosen host learning the device IP of
/// a user who configured Tor.
class _RecordingFactory implements OutboundHttpFactory {
  final List<UserProxySettings> queries = [];
  final bool block;
  int requests = 0;

  _RecordingFactory({this.block = false});

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    queries.add(settings);
    if (block) return const OutboundClientBlocked('blocked by test fake');
    return OutboundClientReady(MockClient((_) async {
      requests++;
      return http.Response(
        '<html><head><title>Fetched Title</title></head><body></body></html>',
        200,
      );
    }));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(resetOutboundHttp);

  test('the title probe asks for the site\'s own proxy', () async {
    final factory = _RecordingFactory();
    outboundHttp = factory;

    final title = await getPageTitle(
      'https://per-site.example/a',
      proxy: UserProxySettings(type: ProxyType.HTTP, address: '127.0.0.1:8080'),
    );

    expect(title, equals('Fetched Title'));
    expect(factory.queries, hasLength(1));
    expect(factory.queries.single.type, equals(ProxyType.HTTP));
    expect(factory.queries.single.address, equals('127.0.0.1:8080'));
  });

  test('a site on DEFAULT resolves through the global proxy', () async {
    GlobalOutboundProxy.setForTest(
      UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:9050'),
    );
    final factory = _RecordingFactory();
    outboundHttp = factory;

    await getPageTitle('https://default-proxy.example/a');

    expect(factory.queries, hasLength(1));
    expect(factory.queries.single.type, equals(ProxyType.SOCKS5));
    expect(factory.queries.single.address, equals('127.0.0.1:9050'));
  });

  test('a blocked client aborts the fetch instead of going direct', () async {
    final factory = _RecordingFactory(block: true);
    outboundHttp = factory;

    final title = await getPageTitle('https://blocked.example/a');

    expect(title, isNull);
    expect(factory.requests, isZero);
  });
}
