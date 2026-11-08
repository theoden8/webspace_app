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

  /// GET [url] through the real page-steered client on [route] (DEFAULT when
  /// omitted). Returns the error it fails with, or null when the request
  /// completed.
  Future<Object?> fetch(String url,
      {String? allowPrivateHost, ProxyRoute? route}) async {
    final result =
        pageSteeredClient(route ?? OutboundProxy.app.resolved,
                allowPrivateHost: allowPrivateHost)
            .result;
    if (result is! OutboundClientReady) {
      return StateError('no client: $result');
    }
    final client = result.client;
    try {
      await client.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      return null;
    } on http.ClientException catch (e) {
      return e;
    } on IOException catch (e) {
      return e;
    } on TimeoutException catch (e) {
      return e;
    } finally {
      client.close();
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

    test('a proxy 302 to a loopback literal does not connect direct', () async {
      // An auto-following fetch (favicon/icon bytes) under an HTTP proxy: the
      // proxy answers 302 -> http://127.0.0.1:<private>/. If the client follows
      // internally and _httpProxyClient's localhost bypass kicks in, hop 2 would
      // connect direct to the loopback. It must not.
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((req) async {
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

      expect(privateConnections, 0,
          reason: 'a redirect to a loopback literal must not connect direct, '
              'even under a proxy');
    });
  });
}
