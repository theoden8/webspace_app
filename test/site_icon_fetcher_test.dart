// The fetch path for page icons on webviews that report none (ICON-013):
// decoding, the per-webview cache, and the network guard on a URL the page
// chose.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_fetcher.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/user_script_bridge_fakes.dart';

Uint8List png(int width, [int? height]) => Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height ?? width)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeSiteIcon', () {
    test('keeps an icon within the bounds as it is', () async {
      final icon = await decodeSiteIcon(png(64));
      expect((icon!.width, icon.height), (64, 64));
      expect(pngDimensions(icon.png), (width: 64, height: 64));
    });

    test('scales a large icon down to the edge WebView uses', () async {
      final icon = await decodeSiteIcon(png(512));
      expect((icon!.width, icon.height), (kMaxSiteIconEdge, kMaxSiteIconEdge));
      final wide = await decodeSiteIcon(png(384, 192));
      expect((wide!.width, wide.height), (192, 96));
    });

    test('decodes an .ico', () async {
      final ico = Uint8List.fromList(
          img.encodeIco(img.Image(width: 48, height: 48)));
      final icon = await decodeSiteIcon(ico);
      expect((icon!.width, icon.height), (48, 48));
    });

    test('null under the floor, over the decode bound, or not an image',
        () async {
      expect(await decodeSiteIcon(png(16)), isNull);
      expect(await decodeSiteIcon(png(kMaxSiteIconDecodeEdge + 1, 64)), isNull);
      expect(await decodeSiteIcon(Uint8List.fromList(utf8.encode('<html>'))),
          isNull);
    });
  });

  group('SiteIconFetcher', () {
    test('offers the largest usable icon', () async {
      final served = {
        'https://example.com/16.png': png(16),
        'https://example.com/48.png': png(48),
        'https://example.com/96.png': png(96),
      };
      final fetcher =
          SiteIconFetcher(fetch: (url, _) async => served[url]);
      final icon = await fetcher.best(served.keys.toList(), 'https://example.com/');
      expect(icon!.edge, 96);
    });

    test('decodes a data: link without a request', () async {
      final requested = <String>[];
      final fetcher = SiteIconFetcher(fetch: (url, _) async {
        requested.add(url);
        return null;
      });
      final data = 'data:image/png;base64,${base64Encode(png(40))}';
      final icon = await fetcher.best([data], 'https://example.com/');
      expect(icon!.edge, 40);
      expect(requested, isEmpty);
    });

    test('fetches a link once per webview, even an unusable one', () async {
      final requested = <String>[];
      final fetcher = SiteIconFetcher(fetch: (url, _) async {
        requested.add(url);
        return url.endsWith('16.png') ? png(16) : png(64);
      });
      const urls = ['https://example.com/16.png', 'https://example.com/64.png'];
      expect((await fetcher.best(urls, 'https://example.com/'))!.edge, 64);
      expect((await fetcher.best(urls, 'https://example.com/b'))!.edge, 64);
      expect(requested, urls);
    });

    test('a failed request is tried again for the next document', () async {
      var attempts = 0;
      final fetcher = SiteIconFetcher(fetch: (url, _) async {
        attempts++;
        return attempts == 1 ? null : png(64);
      });
      const urls = ['https://example.com/a.png'];
      expect(await fetcher.best(urls, 'https://example.com/'), isNull);
      expect((await fetcher.best(urls, 'https://example.com/'))!.edge, 64);
      expect(attempts, 2);
    });

    test('passes the declaring document along', () async {
      final documents = <String>[];
      final fetcher = SiteIconFetcher(fetch: (url, document) async {
        documents.add(document);
        return png(64);
      });
      await fetcher.best(['https://cdn.test/a.png'], 'https://example.com/p');
      expect(documents, ['https://example.com/p']);
    });
  });

  group('fetchPageIconBytes', () {
    final direct = UserProxySettings(type: ProxyType.DEFAULT);
    late FakeOutboundFactory factory;

    void serve(http.Response Function(http.Request request) responder) {
      factory = FakeOutboundFactory(responder);
      outboundHttp = factory;
    }

    setUp(() => stubHostLookup({'rebind.test': ['192.168.1.1']}));
    tearDown(resetOutboundHttp);
    tearDown(resetHostLookup);

    Future<Uint8List?> get(
      String url, {
      String documentHost = 'example.com',
      bool Function(Uri target)? allowed,
    }) =>
        fetchPageIconBytes(
          url,
          documentHost: documentHost,
          proxy: direct,
          allowed: allowed ?? (_) => true,
        );

    test('returns the body of a 200', () async {
      serve((_) => http.Response.bytes(png(64), 200));
      expect(pngDimensions((await get('https://cdn.test/a.png'))!),
          (width: 64, height: 64));
    });

    test('nothing for a non-200', () async {
      serve((_) => http.Response('gone', 404));
      expect(await get('https://cdn.test/a.png'), isNull);
    });

    test('the site blockers refuse the link before any request', () async {
      serve((_) => http.Response.bytes(png(64), 200));
      expect(
          await get('https://tracker.test/a.png',
              allowed: (u) => u.host != 'tracker.test'),
          isNull);
      expect(factory.requested, isEmpty);
    });

    test('a private address is refused unless it is the page host', () async {
      serve((_) => http.Response.bytes(png(64), 200));
      expect(await get('http://127.0.0.1:8080/a.png'), isNull);
      expect(await get('http://rebind.test/a.png'), isNull,
          reason: 'a name that resolves into a private range');
      expect(factory.requested, isEmpty);
      expect(
          await get('http://127.0.0.1:8080/a.png', documentHost: '127.0.0.1'),
          isNotNull,
          reason: 'a LAN site serves its own icon');
    });

    test('every redirect hop is checked again', () async {
      serve((request) => switch (request.url.path) {
            '/to-private' => http.Response('', 302,
                headers: {'location': 'http://10.0.0.1/a.png'}),
            '/to-blocked' => http.Response('', 301,
                headers: {'location': 'https://tracker.test/a.png'}),
            '/to-http' => http.Response('', 302,
                headers: {'location': 'http://cdn.test/a.png'}),
            '/to-ok' => http.Response('', 307, headers: {'location': '/a.png'}),
            _ => http.Response.bytes(png(64), 200),
          });
      bool allowed(Uri u) => u.host != 'tracker.test';
      expect(await get('https://cdn.test/to-private', allowed: allowed), isNull);
      expect(await get('https://cdn.test/to-blocked', allowed: allowed), isNull);
      expect(await get('https://cdn.test/to-http', allowed: allowed), isNull,
          reason: 'https must not drop to http');
      expect(await get('https://cdn.test/to-ok', allowed: allowed), isNotNull);
      expect(factory.requested.map((u) => u.toString()),
          isNot(contains('http://10.0.0.1/a.png')));
    });

    test('gives up on a long redirect chain', () async {
      serve((request) {
        final n = int.parse(request.url.pathSegments.last);
        return http.Response('', 302, headers: {'location': '/hop/${n + 1}'});
      });
      expect(await get('https://cdn.test/hop/0'), isNull);
      expect(factory.requested.length, lessThanOrEqualTo(4));
    });

    test('refuses a body over the limit', () async {
      serve((_) => http.Response.bytes(
          Uint8List(kMaxPageIconBytes + 1), 200));
      expect(await get('https://cdn.test/a.png'), isNull);
    });
  });
}
