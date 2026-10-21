// Which hosts the icon service asks (ICON-014): only the site itself, never
// Google's or DuckDuckGo's icon service.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/global_outbound_proxy.dart';

import 'helpers/fake_outbound.dart';

const _site = 'https://example.com/';
const _google = 'https://www.google.com/s2/favicons?domain=example.com&sz=256';
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

  test('ICON-014: gmail.com is asked about only as itself', () async {
    await getFaviconUrlStream('https://gmail.com/').drain<void>();
    expect(hosts(), {'gmail.com'});
  });

  test('LEAK-016: an onion service is asked about only through itself',
      () async {
    const onion =
        'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
    await getFaviconUrlStream('https://$onion/').drain<void>();
    expect(hosts(), {onion},
        reason: 'any other host would learn which onion service is opened');
  });

  test('ICON-014: a service URL an earlier release kept on disk reads as '
      'absent', () async {
    SharedPreferences.setMockInitialValues({
      'favicon_url_$_site': _google,
      'favicon_url_https://other.test/': 'https://other.test/icon.png',
    });
    await FaviconUrlCache.initialize();
    expect(FaviconUrlCache.get(_site), isNull);
    expect(FaviconUrlCache.get('https://other.test/'),
        'https://other.test/icon.png');
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

  test('isPublicIconServiceUrl names only the two services', () {
    expect(isPublicIconServiceUrl(_google), isTrue);
    expect(
        isPublicIconServiceUrl('https://icons.duckduckgo.com/ip3/a.test.ico'),
        isTrue);
    expect(isPublicIconServiceUrl('https://www.google.com/favicon.ico'),
        isFalse);
    expect(isPublicIconServiceUrl('https://example.com/s2/favicons'), isFalse);
  });
}
