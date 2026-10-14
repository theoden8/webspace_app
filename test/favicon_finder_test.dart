import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

    final favicons = await FaviconFinder.getAll('https://example.com/');

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

    final favicons = await FaviconFinder.getAll('https://example.com/');

    expect(favicons, isEmpty);
    expect(site.requested.map((u) => u.path), contains('/short.ico'));
  });

  test('a page URL without a host asks for nothing', () async {
    final site = _site('');
    outboundHttp = site;

    expect(await FaviconFinder.getAll('https:///page'), isEmpty);
    expect(site.queries, isEmpty);
  });
}
