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
    _deleteWhileCacheWrites(dir);
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

  group('LOC-006: the map waits for the user', () {
    Future<List<Object?>> openPicker(WidgetTester tester) async {
      final popped = <Object?>[];
      await pumpLocalized(tester,
          size: const Size(800, 1400),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => popped.add(await Navigator.of(context)
                  .push<LocationPickerResult>(MaterialPageRoute(
                      builder: (_) => const LocationPickerScreen()))),
              child: const Text('open'),
            ),
          ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return popped;
    }

    Future<void> awaitTiles(WidgetTester tester) async {
      for (var i = 0; i < 20 && outbound.requested.isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(outbound.requested, isNotEmpty);
    }

    testWidgets('LOC-006: opening it fetches nothing, names the tile host and '
        'takes coordinates', (tester) async {
      await openPicker(tester);
      expect(find.byType(FlutterMap), findsNothing);
      expect(outbound.queries, isEmpty);
      expect(find.text(en.locationPickerPrivacyNotice('tile.openstreetmap.org')),
          findsOneWidget);
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields.where((f) => f.enabled ?? true), hasLength(3),
          reason: 'latitude, longitude and accuracy');
    });

    testWidgets('LOC-006: typed coordinates come back on Done with no map',
        (tester) async {
      final popped = await openPicker(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '51.5');
      await tester.enterText(fields.at(1), '-0.12');
      await tester.enterText(fields.at(2), '30');
      await tester.tap(find.text(en.commonDone));
      await tester.pumpAndSettle();

      expect(popped, hasLength(1));
      final result = popped.single! as LocationPickerResult;
      expect((result.latitude, result.longitude, result.accuracy),
          (51.5, -0.12, 30.0));
      expect(outbound.queries, isEmpty);
      expect(outbound.requested, isEmpty);
    });

    testWidgets('LOC-006: a tap on the loaded map sets the coordinates and '
        'the pin', (tester) async {
      await openPicker(tester);
      await tester.tap(find.text(en.locationPickerLoadMap));
      await tester.pump();
      expect(find.byIcon(Icons.location_pin), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)) +
          const Offset(40, -30));
      await tester.pump(const Duration(milliseconds: 500));

      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      final lat = double.parse(fields[0].controller!.text);
      final lng = double.parse(fields[1].controller!.text);
      expect(lat, greaterThan(0), reason: 'above the centre, north of 0');
      expect(lng, greaterThan(0), reason: 'right of the centre, east of 0');
      expect(find.byIcon(Icons.location_pin), findsOneWidget);
    });

    for (final url in [
      AppPref.osmTileUrl.fallback,
      'https://tiles.example.org/{z}/{x}/{y}.png',
    ]) {
      testWidgets('LOC-006: Load map fetches from $url, as the app names '
          'itself, with the attribution on the map', (tester) async {
        await AppPref.osmTileUrl.set(url);
        await openPicker(tester);
        await tester.tap(find.text(en.locationPickerLoadMap));
        await tester.pump();
        expect(find.byType(FlutterMap), findsOneWidget);

        final layer = tester.widget<TileLayer>(find.byType(TileLayer));
        expect(layer.urlTemplate, url);
        final layerAgent = layer.tileProvider.headers['User-Agent'] ?? '';
        expect(layerAgent, startsWith('Webspace'));
        expect(layerAgent, contains('(+https://github.com/theoden8/webspace_app)'));

        // The process's tile cache already holds the default URL's tiles a
        // test above fetched, so only a URL no test fetched shows requests.
        if (url != AppPref.osmTileUrl.fallback) await awaitTiles(tester);
        final host = Uri.parse(url.replaceAll(RegExp('[{}]'), '')).host;
        for (final request in outbound.requests) {
          expect(request.url.scheme, 'https');
          expect(request.url.host, host);
          final agent = request.headers['User-Agent'] ?? '';
          expect(agent, startsWith('Webspace'));
          expect(agent, contains('(+https://github.com/theoden8/webspace_app)'));
          expect(agent, isNot(contains('flutter_map')));
          expect(request.headers['Cache-Control'] ?? '', isNot(contains('no-cache')));
          expect(request.headers['Pragma'] ?? '', isNot(contains('no-cache')));
        }

        final spans = <TextSpan>[];
        for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
          text.text.visitChildren((span) {
            if (span is TextSpan) spans.add(span);
            return true;
          });
        }
        final osm = spans.singleWhere((s) => s.text == 'OpenStreetMap');
        expect(osm.recognizer, isNotNull, reason: 'the word is the link');
        expect(osm.style?.decoration, TextDecoration.underline);
        expect(spans.where((s) => s.text == en.locationPickerReportMapIssue),
            hasLength(1));
      });
    }
  });
}

/// Deletes [dir] while flutter_map's cache worker may still be writing the
/// tiles a test fetched into it: the worker is an isolate of its own, so it
/// drains its queue while this one sleeps, and a delete that met a file it
/// wrote mid-walk ("Directory not empty") goes again. Its own `destroy()`
/// cannot be awaited here: the worker reports its exit through a port the
/// test's fake-time zone opened.
void _deleteWhileCacheWrites(Directory dir) {
  final notEmpty = Platform.isMacOS ? 66 : 39; // ENOTEMPTY
  for (var attempt = 0;; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode != notEmpty || attempt >= 50) rethrow;
      sleep(const Duration(milliseconds: 20));
    }
  }
}
