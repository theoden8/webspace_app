// Exporting a site's icon (DEVTOOLS-009 Save icon, HS-003 home shortcut)
// saves the icon the drawer shows, in the drawer's order.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/icon_png_export.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/global_outbound_proxy.dart';

import 'helpers/fake_outbound.dart';

const _site = 'https://github.com/';
const _fetched = 'https://github.githubassets.com/favicons/favicon.png';

Uint8List _png(int size) =>
    Uint8List.fromList(img.encodePng(img.Image(width: size, height: size)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeOutbound factory;
  late SiteIconStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    clearFaviconCache();
    factory =
        FakeOutbound(responder: (_) => http.Response.bytes(_png(16), 200));
    outboundHttp = factory;
    store = SiteIconStore(store: MemoryFileStore());
    await store.initialize();
  });

  tearDown(() {
    resetOutboundHttp();
    clearFaviconCache();
  });

  test('the page icon the site produced wins over the cached favicon URL',
      () async {
    final pageIcon = _png(64);
    await store.offer(_site, SiteIcon(pageIcon, 64, 64), persist: true);

    final saved = await displayedSiteIconAsPng(_site,
        resolvedIconUrl: _fetched, siteIcons: store);

    expect(saved, pageIcon);
    expect(factory.requested, isEmpty);
  });

  test('a custom icon wins over the page icon', () async {
    final custom = _png(48);
    await store.offer(_site, SiteIcon(_png(64), 64, 64), persist: true);

    final saved = await displayedSiteIconAsPng(_site,
        customIcon: custom, resolvedIconUrl: _fetched, siteIcons: store);

    expect(saved, custom);
    expect(factory.requested, isEmpty);
  });

  test('without either, the fetched favicon is exported', () async {
    final saved = await displayedSiteIconAsPng(_site,
        resolvedIconUrl: _fetched, siteIcons: store);

    expect(saved, isNotNull);
    expect(pngDimensions(saved!), (width: 16, height: 16));
    expect(factory.requested, [Uri.parse(_fetched)]);
  });
}
