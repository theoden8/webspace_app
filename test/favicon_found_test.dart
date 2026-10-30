// A site's icon is one icon wherever the site shows (ICON-017): an icon whose
// own search, or its own fetch of the image, came back with nothing takes what
// a later one brings, and one that fails never takes back what another
// brought meanwhile.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:webspace/screens/add_site.dart'
    show FaviconUrlCache, UnifiedFaviconImage;
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';

import 'helpers/fake_outbound.dart';

final Uint8List _png64 =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">'
    '<rect width="1" height="1" fill="#e33"/></svg>';

http.Response _online(http.Request req) => switch (req.url.path) {
      '/' => http.Response(
          '<html><head><link rel="icon" href="/icon.png"></head></html>', 200),
      '/icon.png' => http.Response.bytes(_png64, 200,
          headers: {'content-type': 'image/png'}),
      '/icon.svg' => http.Response(_svg, 200,
          headers: {'content-type': 'image/svg+xml'}),
      _ => http.Response('', 404),
    };

http.Response _offline(http.Request req) => http.Response('', 404);

final _drawn = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_FaviconBytesImage');

const _preview = Key('preview');
const _tile = Key('tile');

Finder _inPreview(Finder matching) =>
    find.descendant(of: find.byKey(_preview), matching: matching);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// A folder's preview of [site], drawn now and kept, and the site's tile,
/// drawn once the returned notifier is set, as opening the folder draws it.
Future<ValueNotifier<bool>> _pumpPreview(WidgetTester tester,
    {required String site}) async {
  final tileShown = ValueNotifier(false);
  addTearDown(tileShown.dispose);
  Widget icon(Key key) => UnifiedFaviconImage(
      key: key, url: site, size: 24, proxy: OutboundProxy.app);
  await tester.pumpWidget(MaterialApp(
    home: ValueListenableBuilder<bool>(
      valueListenable: tileShown,
      builder: (context, shown, _) => Column(children: [
        icon(_preview),
        if (shown) icon(_tile),
      ]),
    ),
  ));
  await _settle(tester);
  return tileShown;
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
    final tileShown = await _pumpPreview(tester, site: 'https://preview.test/');
    expect(_inPreview(_drawn), findsNothing);
    expect(_inPreview(find.byIcon(Icons.language)), findsOneWidget,
        reason: 'the search found nothing, so the globe stands in');

    factory.responder = _online;
    tileShown.value = true;
    await _settle(tester);
    expect(find.descendant(of: find.byKey(_tile), matching: _drawn),
        findsOneWidget);
    expect(_inPreview(_drawn), findsOneWidget,
        reason: 'the preview takes the icon the tile\'s search found');
    expect(_inPreview(find.byType(Image)), findsOneWidget);
  });

  testWidgets(
      'ICON-017: a folder preview whose image did not come at launch takes it '
      'once its site\'s tile fetches it', (tester) async {
    const site = 'https://image.test/';
    await FaviconUrlCache.initialize();
    await FaviconUrlCache.set(site, faviconUrl: '${site}icon.png');
    final tileShown = await _pumpPreview(tester, site: site);
    expect(_inPreview(find.byType(Image)), findsNothing);
    expect(_inPreview(find.byIcon(Icons.language)), findsOneWidget,
        reason: 'the icon is known, but its image did not come');

    factory.responder = _online;
    tileShown.value = true;
    await _settle(tester);
    expect(find.descendant(of: find.byKey(_tile), matching: find.byType(Image)),
        findsOneWidget);
    expect(_inPreview(find.byType(Image)), findsOneWidget,
        reason: 'the preview takes the image the tile fetched');
    expect(_inPreview(find.byIcon(Icons.language)), findsNothing);
  });

  testWidgets(
      'ICON-017: a folder preview whose SVG did not come at launch takes it '
      'once its site\'s tile fetches it', (tester) async {
    const site = 'https://vector.test/';
    await FaviconUrlCache.initialize();
    await FaviconUrlCache.set(site, faviconUrl: '${site}icon.svg');
    final tileShown = await _pumpPreview(tester, site: site);
    expect(_inPreview(find.byType(SvgPicture)), findsNothing);

    factory.responder = _online;
    tileShown.value = true;
    await _settle(tester);
    expect(find.descendant(of: find.byKey(_tile), matching: find.byType(SvgPicture)),
        findsOneWidget);
    expect(_inPreview(find.byType(SvgPicture)), findsOneWidget,
        reason: 'the preview takes the SVG the tile fetched');
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

  for (final (kind, path, fetch) in [
    (
      'image',
      '/icon.png',
      (String url) => getIconBytes(url, proxy: OutboundProxy.app),
    ),
    (
      'SVG',
      '/icon.svg',
      (String url) => getSvgContent(url, proxy: OutboundProxy.app),
    ),
  ]) {
    test(
        'ICON-017: an $kind fetch that fails while another brings it answers '
        'with what the other brought', () async {
      final url = 'https://overlap.test$path';
      final release = Completer<void>();
      var asked = 0;
      var online = true;
      factory.responder = (req) async {
        if (++asked == 1) await release.future;
        return online ? _online(req) : _offline(req);
      };
      final announced = <String>[];
      final sub = iconImagesFetched.listen(announced.add);
      addTearDown(sub.cancel);

      final stalled = fetch(url);
      await pumpEventQueue();
      final brought = await fetch(url);
      expect(brought, isNotNull);

      online = false;
      release.complete();
      expect(await stalled, brought,
          reason: 'the stalled fetch failed, and keeps what the other brought');
      await pumpEventQueue();
      expect(announced, [url], reason: 'announced by the fetch that brought it');
    });
  }
}
