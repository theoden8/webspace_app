// A site's icon is one icon wherever the site shows (ICON-017): an icon whose
// own search found nothing takes the one a later search finds, and a search
// that fails never takes back an icon another search found meanwhile.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';

import 'helpers/fake_outbound.dart';

final Uint8List _png64 =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));

http.Response _online(http.Request req) => switch (req.url.path) {
      '/' => http.Response(
          '<html><head><link rel="icon" href="/icon.png"></head></html>', 200),
      '/icon.png' => http.Response.bytes(_png64, 200,
          headers: {'content-type': 'image/png'}),
      _ => http.Response('', 404),
    };

http.Response _offline(http.Request req) => http.Response('', 404);

final _drawn = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_FaviconBytesImage');

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeOutbound factory;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    clearFaviconCache();
    factory = FakeOutbound(responder: _offline);
    outboundHttp = factory;
  });

  tearDown(() {
    resetOutboundHttp();
    clearFaviconCache();
  });

  testWidgets(
      'ICON-017: a folder preview drawn offline takes the icon its site\'s '
      'tile finds later', (tester) async {
    const site = 'https://preview.test/';
    const preview = Key('preview');
    final tileShown = ValueNotifier(false);
    addTearDown(tileShown.dispose);
    Widget icon(Key key) => UnifiedFaviconImage(
        key: key, url: site, size: 24, proxy: OutboundProxy.app);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: tileShown,
        builder: (context, shown, _) => Column(children: [
          icon(preview),
          if (shown) icon(const Key('tile')),
        ]),
      ),
    ));
    await _settle(tester);
    expect(find.descendant(of: find.byKey(preview), matching: _drawn),
        findsNothing);
    expect(
        find.descendant(
            of: find.byKey(preview), matching: find.byIcon(Icons.language)),
        findsOneWidget,
        reason: 'the search found nothing, so the globe stands in');

    factory.responder = _online;
    tileShown.value = true;
    await _settle(tester);
    expect(find.descendant(of: find.byKey(const Key('tile')), matching: _drawn),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(preview), matching: _drawn),
        findsOneWidget,
        reason: 'the preview takes the icon the tile\'s search found');
    expect(
        find.descendant(
            of: find.byKey(preview), matching: find.byType(Image)),
        findsOneWidget);
  });

  test(
      'ICON-017: a search that fails while another finds the icon answers '
      'with the found one', () async {
    const site = 'https://overlap.test/';
    final release = Completer<void>();
    var pages = 0;
    var online = true;
    factory.responder = (req) async {
      if (req.url.path == '/' && ++pages == 1) await release.future;
      return online ? _online(req) : _offline(req);
    };
    final announced = <String>[];
    final sub = faviconsFound.listen(announced.add);
    addTearDown(sub.cancel);

    final stalled = getFaviconUrlStream(site, proxy: OutboundProxy.app).toList();
    await pumpEventQueue();
    final found =
        await getFaviconUrlStream(site, proxy: OutboundProxy.app).single;
    expect(Uri.parse(found.url).path, '/icon.png');

    online = false;
    release.complete();
    final late = await stalled;
    expect([for (final u in late) u.url], [found.url],
        reason: 'the stalled search found nothing, and keeps the found icon');

    factory.requests.clear();
    final again = await getFaviconUrlStream(site, proxy: OutboundProxy.app).single;
    expect(again.url, found.url);
    expect(factory.requested, isEmpty, reason: 'answered from the cache');
    await pumpEventQueue();
    expect(announced, [site], reason: 'announced once, by the search that found it');
  });
}
