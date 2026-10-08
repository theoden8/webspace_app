import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/fake_outbound.dart';

Future<AppProxyFetch> _fetch(
  FakeOutbound factory, {
  String url = 'https://a.example/x',
  int? maxBytes,
}) {
  outboundHttp = factory;
  return fetchViaAppProxy(Uri.parse(url), tag: LogTag.test, maxBytes: maxBytes);
}

FakeOutbound _answering(http.Response response) =>
    FakeOutbound(responder: (_) => response);

void main() {
  setUp(GlobalOutboundProxy.resetForTest);
  tearDown(() {
    resetOutboundHttp();
    GlobalOutboundProxy.resetForTest();
  });

  test('a 200 comes back whole, decoded per its content type', () async {
    final result = await _fetch(_answering(http.Response('héllo', 200,
        headers: {'content-type': 'text/plain; charset=utf-8'})));
    expect(result, isA<Fetched>());
    expect((result as Fetched).response.body, 'héllo');
  });

  test('goes through the app-wide proxy', () async {
    GlobalOutboundProxy.setForTest(
        UserProxySettings(type: ProxyType.HTTP, address: '10.0.0.1:3128'));
    final factory = FakeOutbound();
    await _fetch(factory);
    expect(factory.lastQuery!.address, '10.0.0.1:3128');
  });

  test('a proxy that cannot be honoured is refused, never sent direct',
      () async {
    final factory = FakeOutbound()..block = true;
    expect(await _fetch(factory), isA<FetchRefused>());
    expect(factory.requests, isEmpty);
  });

  test('another status is a failure', () async {
    final result = await _fetch(_answering(http.Response('nope', 503)));
    expect(result, isA<FetchFailed>());
    expect((result as FetchFailed).reason, 'HTTP 503');
  });

  test('a transport failure is a failure, not a throw', () async {
    final result = await _fetch(FakeOutbound(
        responder: (_) => throw http.ClientException('connection reset')));
    expect(result, isA<FetchFailed>());
  });

  test('a body over maxBytes is abandoned', () async {
    expect(await _fetch(_answering(http.Response('x' * 11, 200)), maxBytes: 10),
        isA<FetchFailed>());
    expect(await _fetch(_answering(http.Response('x' * 10, 200)), maxBytes: 10),
        isA<Fetched>());
  });

  test('a URL that is not http(s) is never requested', () async {
    final factory = FakeOutbound();
    final result = await _fetch(factory, url: 'ftp://a.example/list.txt');
    expect(result, isA<FetchFailed>());
    expect(factory.queries, isEmpty);
  });
}
