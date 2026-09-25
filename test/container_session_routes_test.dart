// A container's network session outlives its WebViews on Apple, so a site
// whose proxy changed kept loading over connections pooled on its old route
// (reported as a site moved to Tor still showing the device's address). The
// bookkeeping below decides when a WebView must wait for that session to be
// dropped; the native half is proxy_rebind_test.dart on macOS.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_session_routes.dart';

void main() {
  late List<String> resets;
  late Completer<bool> answer;
  late ContainerSessionRoutes routes;

  setUp(() {
    resets = [];
    answer = Completer<bool>();
    routes = ContainerSessionRoutes(reset: (id) {
      resets.add(id);
      return answer.future;
    });
  });

  test('the first WebView on a container binds its route at once', () {
    expect(routes.admit('ws-a', 'direct'), isNull);
    expect(routes.admit('ws-a', 'direct'), isNull,
        reason: 'the same route again rides the same session, as it should');
    expect(routes.routeOf('ws-a'), 'direct');
    expect(resets, isEmpty);
  });

  test('another route waits for the old session to be dropped', () async {
    routes.admit('ws-a', 'direct');
    final reset = routes.admit('ws-a', 'socks5://tor');
    expect(reset, isNotNull);
    expect(resets, ['ws-a']);
    expect(routes.admit('ws-a', 'socks5://tor'), same(reset),
        reason: 'one reset per change, however often the site rebuilds');

    answer.complete(true);
    expect(await reset, isTrue);
    expect(routes.admit('ws-a', 'socks5://tor'), isNull);
    expect(routes.routeOf('ws-a'), 'socks5://tor');
  });

  test('a reset that did not finish keeps the site waiting, and retries', () async {
    routes.admit('ws-a', 'direct');
    final reset = routes.admit('ws-a', 'socks5://tor')!;
    answer.complete(false);
    expect(await reset, isFalse);
    expect(routes.routeOf('ws-a'), 'direct',
        reason: 'the old session is still there, so the site may not bind');

    answer = Completer<bool>()..complete(true);
    final retry = routes.admit('ws-a', 'socks5://tor');
    expect(retry, isNotNull);
    expect(await retry, isTrue);
    expect(resets, ['ws-a', 'ws-a']);
  });

  test('a reset that throws reads as not finished', () async {
    routes = ContainerSessionRoutes(reset: (_) => Future.error(StateError('x')));
    routes.admit('ws-a', 'direct');
    expect(await routes.admit('ws-a', 'socks5://tor'), isFalse);
    expect(routes.routeOf('ws-a'), 'direct');
  });

  test('containers are independent', () {
    routes.admit('ws-a', 'direct');
    expect(routes.admit('ws-b', 'socks5://tor'), isNull);
    expect(resets, isEmpty);
  });
}
