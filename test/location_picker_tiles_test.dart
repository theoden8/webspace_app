import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_path_provider.dart';
import 'helpers/localized.dart';

/// A 1x1 transparent PNG, so a tile the map asks for decodes.
final _tile = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

/// LEAK-002, "OSM map tiles pass global proxy": the picker shows the map
/// only on a client the outbound seam made for the app-global proxy, so a
/// proxy the seam refuses keeps the placeholder rather than putting tiles
/// on the device IP.
void main() {
  late AppLocalizations en;
  late FakeOutbound outbound;
  late Directory dir;

  setUpAll(() async => en = await AppLocalizations.delegate.load(const Locale('en')));

  setUp(() async {
    // flutter_map keeps fetched tiles in the app's cache directory.
    dir = Directory.systemTemp.createTempSync('tiles');
    useFakePathProvider(dir);
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
    GlobalOutboundProxy.setInMemory(
        UserProxySettings(type: ProxyType.HTTP, address: '10.0.0.1:8080'));
    outboundHttp = outbound = FakeOutbound(
        responder: (_) => http.Response.bytes(_tile, 200,
            headers: {'content-type': 'image/png'}));
  });

  tearDown(() {
    resetOutboundHttp();
    GlobalOutboundProxy.resetForTest();
    dir.deleteSync(recursive: true);
  });

  Future<void> loadMap(WidgetTester tester) async {
    await pumpLocalized(tester, home: const LocationPickerScreen());
    expect(find.byType(FlutterMap), findsNothing,
        reason: 'no tile goes out before the user asks for the map');
    expect(outbound.queries, isEmpty);
    await tester.tap(find.text(en.locationPickerLoadMap));
    await tester.pump();
  }

  testWidgets('LEAK-002: the map loads on the client made for the global proxy',
      (tester) async {
    await loadMap(tester);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(outbound.queries.map((q) => (q.type, q.address)),
        [(ProxyType.HTTP, '10.0.0.1:8080')]);
    for (var i = 0; i < 20 && outbound.requested.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outbound.requested, isNotEmpty,
        reason: 'the tiles are fetched through that client');
  });

  testWidgets('LEAK-002: a proxy the seam refuses keeps the placeholder',
      (tester) async {
    outbound.block = true;
    await loadMap(tester);
    expect(find.byType(FlutterMap), findsNothing);
    expect(find.text(en.locationPickerTilesBlocked), findsOneWidget);
    expect(outbound.requested, isEmpty);
  });
}
