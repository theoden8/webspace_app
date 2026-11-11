import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/third_party/favicon/favicon.dart';

import 'helpers/fake_outbound.dart';

/// Serves [page] at the site root and [files] by path, answering as dart:io
/// does for a URL it cannot request: an ArgumentError
/// (_http/http_impl.dart:2983-2990).
FakeOutbound _site(String page, {Map<String, http.Response> files = const {}}) =>
    FakeOutbound(responder: (req) {
      final url = req.url;
      if (url.host.isEmpty || !(url.isScheme('http') || url.isScheme('https'))) {
        throw ArgumentError('No host specified in URI $url');
      }
      if (url.path == '/' || url.path.isEmpty) {
        return http.Response(page, 200, headers: {'content-type': 'text/html'});
      }
      return files[url.path] ?? http.Response('', 404);
    });

http.Response _redirect(String location) =>
    http.Response('', 301, headers: {'location': location});

final List<int> _png = img.encodePng(img.Image(width: 64, height: 64));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(resetOutboundHttp);

  test('a declared icon link the fix-ups leave without a host is dropped',
      () async {
    final site = _site('<html><head>'
        '<link rel="icon" href="http:x.png">'
        '</head></html>');
    outboundHttp = site;

    final favicons = await FaviconFinder.getAll('https://example.com/', proxy: OutboundProxy.app);

    expect(favicons, isEmpty);
    expect([for (final u in site.requested) u.host], everyElement(isNotEmpty));
  });

  test('an .ico shorter than the PNG signature is not an icon', () async {
    // Five bytes: past the ICO length check, short of the 8-byte PNG one.
    final site = _site(
      '<html><head><link rel="icon" href="/short.ico"></head></html>',
      files: {
        '/short.ico': http.Response.bytes([137, 80, 78, 71, 13], 200,
            headers: {'content-type': 'image/x-icon'}),
      },
    );
    outboundHttp = site;

    final favicons = await FaviconFinder.getAll('https://example.com/', proxy: OutboundProxy.app);

    expect(favicons, isEmpty);
    expect(site.requested.map((u) => u.path), contains('/short.ico'));
  });

  test('ICON-002: a home that redirects to another host is asked for that '
      "host's /favicon.ico, and no later host's", () async {
    final icon = http.Response.bytes(_png, 200,
        headers: {'content-type': 'image/png'});
    final site = FakeOutbound(responder: (req) {
      final at = '${req.url.host}${req.url.path}';
      return switch (at) {
        'gmail.test/' => _redirect('https://mail.gmail.test/mail/u/0/'),
        'mail.gmail.test/mail/u/0/' =>
          _redirect('https://accounts.other.test/signin'),
        'accounts.other.test/signin' => http.Response(
            '<html><head></head></html>', 200,
            headers: {'content-type': 'text/html'}),
        'mail.gmail.test/favicon.ico' => icon,
        'accounts.other.test/favicon.ico' => icon,
        _ => http.Response('', 404),
      };
    });
    outboundHttp = site;

    final favicons = await FaviconFinder.getAll('https://gmail.test/', proxy: OutboundProxy.app);

    expect(favicons!.map((f) => f.url),
        ['https://mail.gmail.test/favicon.ico']);
    expect(site.requested.map((u) => '${u.host}${u.path}'),
        isNot(contains('accounts.other.test/favicon.ico')));
  });

  test('ICON-002: a relative link resolves against the document a redirect '
      'landed on', () async {
    final site = FakeOutbound(responder: (req) {
      final at = '${req.url.host}${req.url.path}';
      return switch (at) {
        'example.com/' => _redirect('https://www.example.com/home'),
        'www.example.com/home' => http.Response(
            '<html><head><link rel="icon" href="/icon.png"></head></html>',
            200,
            headers: {'content-type': 'text/html'}),
        'www.example.com/icon.png' => http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'}),
        _ => http.Response('', 404),
      };
    });
    outboundHttp = site;

    final favicons = await FaviconFinder.getAll('https://example.com/', proxy: OutboundProxy.app);

    expect(favicons!.map((f) => Uri.parse(f.url).host), ['www.example.com']);
  });

  test('a redirect loop asks for nothing past the limit', () async {
    final site = FakeOutbound(
        responder: (req) => _redirect('https://loop.test${req.url.path}x'));
    outboundHttp = site;

    expect(await FaviconFinder.getAll('https://loop.test/', proxy: OutboundProxy.app), isEmpty);
    expect(site.requested.length, 6);
  });

  test('a page URL without a host asks for nothing', () async {
    final site = _site('');
    outboundHttp = site;

    expect(await FaviconFinder.getAll('https:///page', proxy: OutboundProxy.app), isEmpty);
    expect(site.queries, isEmpty);
  });

  test('a windows-1251 page still yields its icon (review M3)', () async {
    // The page is labelled windows-1251 and carries bytes that are invalid
    // UTF-8. Strict UTF-8 decoding (the regression) threw and lost the icon;
    // charset-aware decoding falls back to latin1 so the ASCII icon link parses.
    final bytes = <int>[
      ...'<html><head><title>'.codeUnits,
      0xC0, 0xC1, // lone high bytes: valid windows-1251/latin1, invalid UTF-8
      ...'</title><link rel="icon" href="/icon.png"></head></html>'.codeUnits,
    ];
    final site = FakeOutbound(responder: (req) {
      if (req.url.path == '/' || req.url.path.isEmpty) {
        return http.Response.bytes(bytes, 200,
            headers: {'content-type': 'text/html; charset=windows-1251'});
      }
      if (req.url.path == '/icon.png') {
        return http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'});
      }
      return http.Response('', 404);
    });
    outboundHttp = site;

    final favicons =
        await FaviconFinder.getAll('https://example.com/', proxy: OutboundProxy.app);

    expect(favicons, isNotNull);
    expect(favicons!.map((f) => Uri.parse(f.url).path), contains('/icon.png'),
        reason: 'a non-UTF-8 home page must still give up its icon');
  });

  test('a page with several icon links builds one shared client (review M3)',
      () async {
    // One guarded client serves the whole discovery (the page, each icon-link
    // check, each /favicon.ico probe); per-fetch clients (the regression) built
    // one each, losing connection reuse — most of the budget under Tor/SOCKS.
    // queries records every clientFor call, so one shared client reads as 1.
    final icon = http.Response.bytes(_png, 200,
        headers: {'content-type': 'image/png'});
    final site = FakeOutbound(responder: (req) {
      if (req.url.path == '/' || req.url.path.isEmpty) {
        return http.Response(
            '<html><head>'
            '<link rel="icon" href="/a.png">'
            '<link rel="icon" href="/b.png">'
            '<link rel="icon" href="/c.png">'
            '</head></html>',
            200,
            headers: {'content-type': 'text/html'});
      }
      return icon;
    });
    outboundHttp = site;

    await FaviconFinder.getAll('https://example.com/', proxy: OutboundProxy.app);

    expect(site.queries.length, 1,
        reason: 'the discovery builds one shared page-steered client for all its '
            'fetches (page + icons + favicon.ico), not one per fetch');
  });

  test('the discovery deadline cuts a page that never finishes (L1)', () async {
    // The fetches share one client, so no single fetch can close it; the bound
    // lives on withPageSteeredClient (favicon.dart:106). A page whose response
    // never completes otherwise keeps the discovery and its socket open
    // unbounded. Drop the timeout there and getAll hangs here instead of
    // raising, so this test is the deadline's only witness.
    final site =
        FakeOutbound(responder: (_) => Completer<http.Response>().future);
    outboundHttp = site;
    addTearDown(FaviconFinder.resetDiscoveryTimeout);
    FaviconFinder.discoveryTimeout = const Duration(milliseconds: 300);

    await expectLater(
      FaviconFinder.getAll('https://example.com/', proxy: OutboundProxy.app),
      throwsA(isA<TimeoutException>()),
    );
  });
}
