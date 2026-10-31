import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    GlobalOutboundProxy.setInMemory(
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

  group('firstBytes', () {
    Future<AppProxyFetch> ranged(FakeOutbound factory) {
      outboundHttp = factory;
      return fetchViaAppProxy(Uri.parse('https://a.example/x'),
          tag: LogTag.test, firstBytes: 4);
    }

    test('asks for the body\'s start and takes the 206', () async {
      final factory = _answering(http.Response('abcd', 206));
      final result = await ranged(factory);
      expect(factory.requests.single.headers['Range'], 'bytes=0-3');
      expect((result as Fetched).response.body, 'abcd');
    });

    test('stops reading a 200 that ignores the range', () async {
      final factory = FakeOutbound(
          client: () => MockClient.streaming((request, _) async =>
              http.StreamedResponse(
                  Stream.fromIterable([
                    'ab'.codeUnits,
                    'cd'.codeUnits,
                    'ef'.codeUnits,
                    for (var i = 0; i < 1000; i++) 'more'.codeUnits,
                  ]),
                  200)));
      final result = await ranged(factory);
      expect((result as Fetched).response.body, 'abcd');
    });

    test('a 206 to a request without it is a failure', () async {
      expect(await _fetch(_answering(http.Response('abcd', 206))),
          isA<FetchFailed>());
    });
  });

  group('timeout', () {
    AppProxyFetch? fetched(
      http.Client Function() client, {
      required FetchTimeout timeout,
      required Duration after,
    }) {
      AppProxyFetch? result;
      fakeAsync((async) {
        outboundHttp = FakeOutbound(client: client);
        unawaited(fetchViaAppProxy(Uri.parse('https://a.example/x'),
                tag: LogTag.test, timeout: timeout)
            .then((r) => result = r));
        async.elapse(after);
      });
      return result;
    }

    /// Ten parts twenty seconds apart, as a package comes through Tor.
    http.Client slow() {
      Stream<List<int>> parts() async* {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(seconds: 20));
          yield 'abcd'.codeUnits;
        }
      }

      return MockClient.streaming(
          (request, _) async => http.StreamedResponse(parts(), 200));
    }

    test('an idle limit takes a slow body whole; a total one gives up on it',
        () {
      expect(
          fetched(slow,
              timeout: const IdleTimeout(Duration(seconds: 60)),
              after: const Duration(minutes: 5)),
          isA<Fetched>().having((f) => f.response.body, 'body', 'abcd' * 10));
      expect(
          fetched(slow,
              timeout: const TotalTimeout(Duration(seconds: 90)),
              after: const Duration(minutes: 5)),
          isA<FetchFailed>()
              .having((f) => f.reason, 'reason', 'not done within 90 s'));
    });

    test('an idle limit gives up on a body that stops', () {
      Stream<List<int>> stops() async* {
        yield 'ab'.codeUnits;
        await Completer<void>().future;
      }

      expect(
          fetched(
              () => MockClient.streaming(
                  (request, _) async => http.StreamedResponse(stops(), 200)),
              timeout: const IdleTimeout(Duration(seconds: 60)),
              after: const Duration(seconds: 61)),
          isA<FetchFailed>()
              .having((f) => f.reason, 'reason', 'nothing arrived for 60 s'));
    });

    test('an idle limit gives up on a server that never answers', () {
      expect(
          fetched(
              () => MockClient.streaming(
                  (request, _) => Completer<http.StreamedResponse>().future),
              timeout: const IdleTimeout(Duration(seconds: 60)),
              after: const Duration(seconds: 61)),
          isA<FetchFailed>());
    });
  });

  test('a URL that is not http(s) is never requested', () async {
    final factory = FakeOutbound();
    final result = await _fetch(factory, url: 'ftp://a.example/list.txt');
    expect(result, isA<FetchFailed>());
    expect(factory.queries, isEmpty);
  });
}
