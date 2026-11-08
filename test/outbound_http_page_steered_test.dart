// SEC-049: the page-steered client judges every connection's destination as it
// connects and connects only to a judged address, so a name that resolves into
// a private range is never reached and a rebind between a check and the connect
// cannot land on the LAN. One invariant for http and https: nothing connects to
// an address the judge did not accept — the judge throws before any socket
// opens, so not even a TCP connection (let alone a TLS ClientHello) reaches it.
//
// The judge runs in the dart:io connection factory, which this reaches through
// the real `pageSteeredClient`; a raw socket on a loopback port stands in for
// the private target and counts every connection it accepts, so a connection
// that should never happen is caught even when no HTTP request would follow.
//
// Verifies US-DR-007 (the resolving half of the user-script SSRF guard, now
// owned here), US-006, LEAK-002, and ICON-013's LAN-site allowance.
//
// Cross-links:
//   docs/bugs/012-page-steered-outbound-reach.md
//   openspec/specs/ip-leakage/spec.md                   LEAK-002
//   openspec/specs/user-scripts/spec.md                 US-006, US-DR-007

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/outbound_http.dart';
// dart:io-only symbols the re-export does not carry (it resolves to the web half
// under analysis): the real pin's private-target error and the env-proxy
// injection point. This is a VM test, so the direct platform import is fine.
import 'package:webspace/services/outbound_http_io.dart'
    show pageSteeredFindProxy, resetPageSteeredFindProxy, PageSteeredPrivateTarget;
import 'package:webspace/settings/proxy.dart';

void main() {
  // No TestWidgetsFlutterBinding: it installs an HttpOverrides that stubs every
  // HttpClient request to 400 without calling the connection factory, which is
  // exactly the judge under test. These run on real loopback sockets, like
  // onion_direct_route_test.

  late ServerSocket privateListener;
  late int privatePort;
  var privateConnections = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    privateConnections = 0;
    // The "private" target: a connection it accepts is a judgement the guard
    // failed to make. A pinned client refuses before connecting, so a correct
    // guard leaves this at zero.
    privateListener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    privateListener.listen((s) {
      privateConnections++;
      s.destroy();
    });
    privatePort = privateListener.port;
  });

  tearDown(() async {
    await privateListener.close();
    resetOutboundHttp();
    resetHostLookup();
    GlobalOutboundProxy.resetForTest();
  });

  /// GET [url] through the real page-steered follower on [route] (DEFAULT when
  /// omitted), the one consumer of a [PageSteeredHttp]. Follows redirects by
  /// hand, so every hop goes through the guarded connect. Returns the error it
  /// fails with, or null when the request completed.
  Future<Object?> fetch(String url,
      {String? allowPrivateHost, ProxyRoute? route}) async {
    try {
      final outcome = await followPageSteered(
        route ?? OutboundProxy.app.resolved,
        url: Uri.parse(url),
        allowPrivateHost: allowPrivateHost,
        follow: PageSteeredFollow<void>(
          permit: (_) async => true,
          read: (response) => response.stream.drain<void>(),
        ),
      ).timeout(const Duration(seconds: 5));
      return switch (outcome) {
        PageSteeredValue() => null,
        PageSteeredRefused(:final reason) => StateError(reason),
      };
    } on http.ClientException catch (e) {
      return e;
    } on IOException catch (e) {
      return e;
    } on TimeoutException catch (e) {
      return e;
    }
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

  group('a name resolving private is refused, nothing connects (SEC-049, US-DR-007)',
      () {
    for (final scheme in const ['http', 'https']) {
      test('$scheme: a name resolving onto loopback is refused, nothing sent',
          () async {
        hostLookup = (_) async => const ['127.0.0.1'];
        final err = await fetch('$scheme://evil.test:$privatePort/');
        expect(err, isNotNull, reason: 'the fetch must fail, not connect');
        await settle();
        expect(privateConnections, 0,
            reason: '$scheme: nothing — not even a TLS ClientHello — reached the '
                'private address');
      });
    }

    test('a name resolving into the LAN is refused (US-006)', () async {
      hostLookup = (_) async => const ['192.168.1.10'];
      expect(await fetch('http://nas.example:$privatePort/'), isNotNull);
      await settle();
      expect(privateConnections, 0);
    });

    test('one private address among public ones is enough to refuse', () async {
      hostLookup = (_) async => const ['93.184.216.34', '127.0.0.1'];
      expect(await fetch('http://mixed.example:$privatePort/'), isNotNull);
      await settle();
      expect(privateConnections, 0);
    });

    test('the host is resolved once per connection (no re-resolve at connect)',
        () async {
      var calls = 0;
      hostLookup = (_) async {
        calls++;
        return const ['127.0.0.1'];
      };
      await fetch('http://evil.test:$privatePort/');
      expect(calls, 1);
    });

    test('an onion name needs Tor, not a direct page-steered connection',
        () async {
      hostLookup = (_) async => const ['127.0.0.1'];
      final err = await fetch('http://abcdefghij234567.onion:$privatePort/');
      expect(err, isNotNull);
      await settle();
      expect(privateConnections, 0);
    });

    test('a loopback literal is refused without resolving it', () async {
      var calls = 0;
      hostLookup = (_) async {
        calls++;
        return const ['93.184.216.34'];
      };
      final err = await fetch('http://127.0.0.1:$privatePort/');
      expect(err, isNotNull);
      await settle();
      expect(privateConnections, 0);
      expect(calls, 0, reason: 'a private literal is refused before any lookup');
    });
  });

  group('allowPrivateHost permits only the document host (ICON-013)', () {
    test('the document host reaches its own private address', () async {
      hostLookup = (_) async => const ['127.0.0.1'];
      // The raw listener is not an http server, so the GET errors once the
      // connection is made; the point is that the connection WAS made.
      await fetch('http://lan.example:$privatePort/',
          allowPrivateHost: 'lan.example');
      await settle();
      expect(privateConnections, greaterThan(0),
          reason: "allowPrivateHost permits the document host's own LAN address");
    });

    test('a different host is still refused under the same allowance', () async {
      hostLookup = (_) async => const ['127.0.0.1'];
      expect(
          await fetch('http://other.example:$privatePort/',
              allowPrivateHost: 'lan.example'),
          isNotNull);
      await settle();
      expect(privateConnections, 0,
          reason: 'the allowance is for the document host alone');
    });
  });

  group('under a proxy the request goes to the proxy, never direct (LEAK-002)',
      () {
    test('a name is carried by the proxy, not connected to directly', () async {
      // A mock HTTP proxy on loopback that only counts the connections it gets.
      var proxyConnections = 0;
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((s) {
        proxyConnections++;
        s.destroy();
      });
      addTearDown(() => proxy.close());

      // internal.example:privatePort would hit the private listener if it were
      // connected to directly; a proxy route must send the name to the proxy and
      // resolve it there, never here.
      hostLookup = (_) async => const ['127.0.0.1'];
      final route = OutboundProxy.ofApp(UserProxySettings(
              type: ProxyType.HTTP, address: '127.0.0.1:${proxy.port}'))
          .resolved;

      await fetch('http://internal.example:$privatePort/x', route: route);
      await settle();

      expect(proxyConnections, greaterThan(0),
          reason: 'the name is carried by the proxy, resolved at the far end');
      expect(privateConnections, 0,
          reason: 'the destination is never connected to directly under a proxy');
    });

    test('a private literal is refused even under a proxy', () async {
      final route = OutboundProxy.ofApp(UserProxySettings(
              type: ProxyType.HTTP, address: '127.0.0.1:1'))
          .resolved;
      final err = await fetch('http://127.0.0.1:$privatePort/', route: route);
      expect(err, isNotNull);
      await settle();
      expect(privateConnections, 0,
          reason: 'a proxy must not become a path to the loopback literal');
    });

    test('a proxy 302 to a loopback literal reaches the proxy at hop 1 only',
        () async {
      // The proxy answers hop 1 with 302 -> http://127.0.0.1:<private>/evil. The
      // follower re-judges hop 2 (a loopback literal) and refuses it before any
      // send, so the proxy never receives it. This is the case the follower
      // closes over an auto-following client: with followRedirects=true the
      // client would send hop 2 to the proxy, and this test would see '/evil'.
      final proxyPaths = <String>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((req) async {
        proxyPaths.add(req.uri.path);
        req.response.statusCode = 302;
        req.response.headers
            .set('location', 'http://127.0.0.1:$privatePort/evil');
        await req.response.close();
      });
      addTearDown(() => proxy.close(force: true));
      final route = OutboundProxy.ofApp(UserProxySettings(
              type: ProxyType.HTTP, address: '127.0.0.1:${proxy.port}'))
          .resolved;

      await fetch('http://public.example/favicon.ico', route: route);
      await settle();

      expect(proxyPaths, ['/favicon.ico'],
          reason: 'the proxy saw only hop 1; hop 2 (the loopback literal) was '
              'refused before any send, not forwarded to the proxy');
      expect(privateConnections, 0,
          reason: 'and nothing connected direct to the loopback either');
    });
  });

  group('a redirect\'s next hop is judged, not just the first (BUG-012)', () {
    test('DEFAULT: a 302 onto a name resolving private is refused at hop 2',
        () async {
      // hop 1 (cdn.test) is the allowed document host and resolves to the
      // loopback redirect server; it answers 302 -> http://nas.test:<private>/.
      // hop 2 (nas.test) is a different host, so it is judged on connect and
      // refused before a byte reaches the private listener. On a DEFAULT route
      // the #949 per-connection pin refuses hop 2 even if the client auto-follows
      // (it judges every connection), so this case does not by itself distinguish
      // the follower; the proxy-302 case above is the one that does.
      hostLookup = (_) async => const ['127.0.0.1'];
      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirect.listen((req) async {
        req.response.statusCode = 302;
        req.response.headers.set('location', 'http://nas.test:$privatePort/');
        await req.response.close();
      });
      addTearDown(() => redirect.close(force: true));

      final err = await fetch('http://cdn.test:${redirect.port}/',
          allowPrivateHost: 'cdn.test');
      expect(err, isNotNull, reason: 'hop 2 must be refused, not followed');
      await settle();
      expect(privateConnections, 0,
          reason: 'the redirect target is judged at the hop, so nothing reached '
              'the private listener');
    });
  });

  group('a timeout cuts the socket, not just the await (BUG-012)', () {
    test('an unbounded body stops arriving once the deadline closes the client',
        () async {
      // The server streams a body forever. The follower applies the timeout
      // inside its own try, so the deadline closes the client and cuts the
      // socket; the body stops arriving. With an external `.timeout` on the
      // follower's future (the old shape), the socket stayed open and the body
      // kept arriving in the background. Measured client-side, where the cut is
      // observable (server-side writes buffer past a close).
      var received = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.bufferOutput = false;
        try {
          while (true) {
            req.response.add(List.filled(256, 7));
            await req.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        } on HttpException {
          // the client went away
        } on SocketException {
          // the client went away
        } on StateError catch (e) {
          // Only the expected write-after-close once the follower cut the
          // socket; any other StateError is a real bug and must surface.
          if (!e.toString().toLowerCase().contains('clos')) rethrow;
        }
      });
      addTearDown(() => server.close(force: true));
      hostLookup = (_) async => const ['127.0.0.1'];

      final outcome = followPageSteered(
        OutboundProxy.app.resolved,
        url: Uri.parse('http://sink.test:${server.port}/'),
        allowPrivateHost: 'sink.test',
        follow: PageSteeredFollow<void>(
          permit: (_) async => true,
          read: (r) => r.stream.forEach((chunk) => received += chunk.length),
          timeout: const Duration(milliseconds: 300),
        ),
      );
      await expectLater(outcome, throwsA(isA<TimeoutException>()));

      final atTimeout = received;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(received, lessThan(atTimeout + 1024),
          reason: 'the deadline closed the client, so little or no more body '
              'arrived after the timeout (it would keep growing by ~15 KB if the '
              'socket stayed open)');
    });
  });

  group('a refused redirect cancels its body, it does not drain it (BUG-012)',
      () {
    test('an endless 3xx body surfaces no uncaught error on the forced close',
        () async {
      // The 302 carries an endless chunked body and points at a host permit
      // refuses. The follower cancels the 3xx body and returns the refusal, so
      // the forced client close cuts the socket cleanly. Draining it instead
      // (unawaited(response.stream.drain())) would keep reading until the close
      // cut it, surfacing as an uncaught ClientException the test zone fails on.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = 302;
        req.response.headers.set('location', 'http://blocked.test/next');
        req.response.bufferOutput = false;
        try {
          while (true) {
            req.response.add(List.filled(256, 7));
            await req.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } on HttpException {
          // the client went away
        } on SocketException {
          // the client went away
        } on StateError catch (e) {
          if (!e.toString().toLowerCase().contains('clos')) rethrow;
        }
      });
      addTearDown(() => server.close(force: true));
      hostLookup = (_) async => const ['127.0.0.1'];

      final outcome = await followPageSteered(
        OutboundProxy.app.resolved,
        url: Uri.parse('http://start.test:${server.port}/'),
        allowPrivateHost: 'start.test',
        follow: PageSteeredFollow<void>(
          // the start host is allowed; the redirect target is not, so the hop
          // is refused before any final response is read.
          permit: (t) async => t.host == 'start.test',
          read: (r) => r.stream.drain<void>(),
        ),
      );
      expect(outcome, isA<PageSteeredRefused<void>>());
      expect((outcome as PageSteeredRefused<void>).kind,
          PageSteeredRefusal.redirect);
      // Let any mishandled 3xx body surface its close as an uncaught error (the
      // client was closed on the follower's return); the test zone fails if so.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  });

  group('a reused client judges each destination behind an env proxy (BUG-012, M1)',
      () {
    test('a second destination resolving private is refused on a pooled '
        'proxy connection', () async {
      // dart:io pools plain-http connections by the env proxy's host:port, so a
      // reused client carries a second destination over the first's connection
      // and the per-connection connectionFactory judge never runs for it. The
      // per-request guard resolves and judges every request, so b.test (which
      // resolves to a private address) is refused even while sharing a.test's
      // pooled proxy connection. On e62d0c8 (one client per fetch) this was
      // refused by a fresh connection's judge; the shared client dropped it.
      final proxied = <String>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((req) async {
        proxied.add(req.uri.host);
        req.response.statusCode = 200;
        req.response.write('ok');
        await req.response.close();
      });
      addTearDown(() => proxy.close(force: true));

      pageSteeredFindProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
      addTearDown(resetPageSteeredFindProxy);
      // a.test (and the proxy) resolve public; b.test resolves into the LAN.
      hostLookup = (host) async =>
          host == 'b.test' ? const ['10.0.0.5'] : const ['93.184.216.34'];

      Object? aErr;
      Object? bErr;
      await withPageSteeredClient(
        OutboundProxy.app.resolved,
        body: (client) async {
          Future<Object?> get(String url) async {
            try {
              final outcome = await followPageSteeredReusing(
                client,
                url: Uri.parse(url),
                follow: PageSteeredFollow<void>(
                  permit: (_) async => true,
                  read: (r) => r.stream.drain<void>(),
                ),
              ).timeout(const Duration(seconds: 5));
              return switch (outcome) {
                PageSteeredValue() => null,
                PageSteeredRefused(:final reason) => StateError(reason),
              };
            } on IOException catch (e) {
              return e;
            } on TimeoutException catch (e) {
              return e;
            }
          }

          aErr = await get('http://a.test/a');
          bErr = await get('http://b.test/b');
        },
      );

      expect(aErr, isNull,
          reason: 'the public destination goes through the proxy');
      expect(bErr, isA<PageSteeredPrivateTarget>(),
          reason: 'the private destination is refused per request, even on the '
              'reused proxy connection');
      expect(proxied, ['a.test'],
          reason: 'only the public destination reached the proxy; b.test was '
              'refused before any byte was sent');
    });
  });
}
