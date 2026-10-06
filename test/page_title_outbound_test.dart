import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/main.dart' show getPageTitle;
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'helpers/fake_outbound.dart';

FakeOutbound _titleFactory({bool block = false}) => FakeOutbound(
      responder: (_) => http.Response(
        '<html><head><title>Fetched Title</title></head><body></body></html>',
        200,
      ),
      blockWhen: (_) => block,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(resetOutboundHttp);

  test('the title probe asks for the site\'s own proxy', () async {
    final factory = _titleFactory();
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
    final factory = _titleFactory();
    outboundHttp = factory;

    await getPageTitle('https://default-proxy.example/a');

    expect(factory.queries, hasLength(1));
    expect(factory.queries.single.type, equals(ProxyType.SOCKS5));
    expect(factory.queries.single.address, equals('127.0.0.1:9050'));
  });

  test('a blocked client aborts the fetch instead of going direct', () async {
    final factory = _titleFactory(block: true);
    outboundHttp = factory;

    final title = await getPageTitle('https://blocked.example/a');

    expect(title, isNull);
    expect(factory.requests, isEmpty);
  });
}
