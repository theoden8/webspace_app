// Which hosts the icon service asks (ICON-014): only the hosts the site
// names, never a third-party icon service.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/host_user_agent.dart';

import 'helpers/fake_outbound.dart';

const _site = 'https://example.com/';
const _browser = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15';
final Uint8List _png64 =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeOutbound factory;

  Set<String> hosts() => factory.requested.map((u) => u.host).toSet();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    clearFaviconCache();
    factory = FakeOutbound(responder: (req) => switch (req.url.path) {
          '/' => http.Response(
              '<html><head><link rel="icon" href="/icon.png"></head></html>',
              200),
          '/icon.png' => http.Response.bytes(_png64, 200,
              headers: {'content-type': 'image/png'}),
          _ => http.Response('', 404),
        });
    outboundHttp = factory;
  });

  tearDown(() {
    resetOutboundHttp();
    clearFaviconCache();
  });

  test('ICON-014: every request goes to the site', () async {
    final updates = await getFaviconUrlStream(_site).toList();
    expect(hosts(), {'example.com'});
    final found = Uri.parse(updates.single.url);
    expect((found.host, found.path), ('example.com', '/icon.png'));
  });

  test('ICON-002: the largest declared icon wins, else /favicon.ico',
      () async {
    final icons = {
      '/small.png': img.encodePng(img.Image(width: 32, height: 32)),
      '/large.png': img.encodePng(img.Image(width: 96, height: 96)),
      '/favicon.ico': _png64,
    };
    var page = '<link rel="icon" href="/small.png">'
        '<link rel="icon" href="/large.png">';
    outboundHttp = factory = FakeOutbound(responder: (req) {
      final icon = icons[req.url.path];
      if (icon != null) {
        return http.Response.bytes(icon, 200,
            headers: {'content-type': 'image/png'});
      }
      return http.Response('<html><head>$page</head></html>', 200);
    });
    final declared = await getFaviconUrlStream(_site).single;
    expect(Uri.parse(declared.url).path, '/large.png');
    expect(declared.quality, 96);

    page = '';
    clearFaviconCache();
    final fallback = await getFaviconUrlStream(_site).single;
    expect(Uri.parse(fallback.url).path, '/favicon.ico');
  });

  test('ICON-002: every icon request names the webview\'s user agent',
      () async {
    HostBrowser.defaultUserAgentForTest = _browser;
    addTearDown(() => HostBrowser.defaultUserAgentForTest = null);
    await getFaviconUrlStream(_site).drain<void>();
    expect(factory.requests, isNotEmpty);
    expect({for (final r in factory.requests) r.headers['user-agent']},
        {_browser});
  });

  test('ICON-002: a site that walls other clients is asked as its webview '
      'asks it', () async {
    HostBrowser.defaultUserAgentForTest = _browser;
    addTearDown(() => HostBrowser.defaultUserAgentForTest = null);
    final wall = http.Response(
        '<html><head><title>Checking your browser</title></head></html>', 200,
        headers: {'content-type': 'text/html'});
    outboundHttp = factory = FakeOutbound(responder: (req) {
      if (req.headers['user-agent'] != _browser) return wall;
      return switch ('${req.url.host}${req.url.path}') {
        'walled.test/' => http.Response('', 301,
            headers: {'location': 'https://www.walled.test/'}),
        'www.walled.test/' => http.Response(
            '<html><head><link rel="icon" href="/icon.png"></head></html>',
            200,
            headers: {'content-type': 'text/html'}),
        'www.walled.test/icon.png' => http.Response.bytes(_png64, 200,
            headers: {'content-type': 'image/png'}),
        _ => http.Response('', 404),
      };
    });
    final found = await getFaviconUrlStream('https://walled.test/').single;
    expect(Uri.parse(found.url).host, 'www.walled.test');
  });

  test('ICON-014: gmail.com is asked about only as itself', () async {
    await getFaviconUrlStream('https://gmail.com/').drain<void>();
    expect(hosts(), {'gmail.com'});
  });

  test('LEAK-016: an onion service is asked about only through itself',
      () async {
    const onion =
        'exampleabcdefghijklmnopqrstuvwxyz234567abcdefghijklmnop.onion';
    await getFaviconUrlStream('https://$onion/').drain<void>();
    expect(hosts(), {onion},
        reason: 'any other host would learn which onion service is opened');
  });

  test('ICON-014: icon URLs an earlier release kept are dropped at startup',
      () async {
    SharedPreferences.setMockInitialValues({
      'favicon_url_$_site': 'https://icons.example.net/example.com.ico',
      'favicon_svg_https://example.com/icon.svg': '<svg/>',
      'theme': 'dark',
    });
    await FaviconUrlCache.initialize();
    expect(FaviconUrlCache.get(_site), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(),
        {'favicon_svg_https://example.com/icon.svg', 'theme'},
        reason: 'only the retired URL entries go');

    await FaviconUrlCache.set(_site, faviconUrl: 'https://example.com/icon.png');
    await FaviconUrlCache.initialize();
    expect(FaviconUrlCache.get(_site), 'https://example.com/icon.png',
        reason: 'what this release keeps survives the next start');
  });

  test('a repeat request is answered from the cache (ICON-008)', () async {
    final first = await getFaviconUrlStream(_site).last;
    factory.requests.clear();
    final again = await getFaviconUrlStream(_site).toList();
    expect(again.single.url, first.url);
    expect(again.single.isFinal, isTrue);
    expect(factory.requested, isEmpty, reason: 'no request goes out');

    invalidateFaviconFor(_site);
    await getFaviconUrlStream(_site).drain<void>();
    expect(factory.requested, isNotEmpty,
        reason: 'an invalidated entry is fetched again');
  });
}
