import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/page_title.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
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
    GlobalOutboundProxy.setInMemory(
      UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:9050'),
    );
    final factory = _titleFactory();
    outboundHttp = factory;

    await getPageTitle('https://default-proxy.example/a');

    expect(factory.queries, hasLength(1));
    expect(factory.queries.single.type, equals(ProxyType.SOCKS5));
    expect(factory.queries.single.address, equals('127.0.0.1:9050'));
  });

  test('a URL the client cannot request has no title and asks for nothing',
      () async {
    // Answers as dart:io does: anything but http(s) with a host is an
    // ArgumentError (_http/http_impl.dart:2983-2990).
    final factory = FakeOutbound(responder: (req) {
      final url = req.url;
      if (url.host.isEmpty || !(url.isScheme('http') || url.isScheme('https'))) {
        throw ArgumentError('No host specified in URI $url');
      }
      return http.Response('<title>Fetched Title</title>', 200);
    });
    outboundHttp = factory;

    for (final url in [
      'about:blank',
      'chrome://settings',
      'file:///imported.html',
      'view-source:https://example.com/',
      'https://',
      'example.com',
    ]) {
      expect(await getPageTitle(url), isNull, reason: url);
    }
    expect(factory.queries, isEmpty);
  });

  test('a blocked client aborts the fetch instead of going direct', () async {
    final factory = _titleFactory(block: true);
    outboundHttp = factory;

    final title = await getPageTitle('https://blocked.example/a');

    expect(title, isNull);
    expect(factory.requests, isEmpty);
  });
}
