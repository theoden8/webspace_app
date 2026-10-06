import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'helpers/fake_path_provider.dart';

/// Minimal GeoJSON FeatureCollection used as a fixture for the parser.
/// Two zones: a square covering "Asia/Tokyo" around (35.68, 139.65) and a
/// disjoint square covering "Europe/London" around (51.5, -0.13). Includes
/// one MultiPolygon entry to exercise the multi-poly branch.
const _fixture = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {"tzid": "Asia/Tokyo"},
      "geometry": {
        "type": "Polygon",
        "coordinates": [
          [[139.0, 35.0], [140.0, 35.0], [140.0, 36.0], [139.0, 36.0], [139.0, 35.0]]
        ]
      }
    },
    {
      "type": "Feature",
      "properties": {"tzid": "Europe/London"},
      "geometry": {
        "type": "MultiPolygon",
        "coordinates": [
          [[[-1.0, 51.0], [1.0, 51.0], [1.0, 52.0], [-1.0, 52.0], [-1.0, 51.0]]]
        ]
      }
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('webspace_tz_test_');
    useFakePathProvider(tmp);
  });

  group('TimezoneLocationService', () {
    test('lookup returns null before any data is loaded', () async {
      // Reset the in-memory state by clearing first.
      await TimezoneLocationService.instance.clear();
      expect(TimezoneLocationService.instance.isReady, isFalse);
      expect(TimezoneLocationService.instance.lookup(35.68, 139.65), isNull);
    });

    test('parses GeoJSON cache from disk and resolves polygons', () async {
      // Write a fixture into the cache file path the service expects.
      final dir = Directory(
          (PathProviderPlatform.instance as FakePathProvider).dir.path);
      final file = File('${dir.path}/tz_polygons.geojson');
      await file.writeAsString(_fixture);

      // Force a fresh load attempt.
      await TimezoneLocationService.instance.clear();
      // After clear() the service drops cache, so re-write the fixture
      // because clear() also deletes the cache file.
      await file.writeAsString(_fixture);
      final ok = await TimezoneLocationService.instance.loadFromCacheIfPresent();
      expect(ok, isTrue);
      expect(TimezoneLocationService.instance.isReady, isTrue);
      expect(TimezoneLocationService.instance.zoneCount, 2);
    });

    test('lookup hits the right zone for points inside each polygon', () {
      expect(
          TimezoneLocationService.instance.lookup(35.68, 139.65), 'Asia/Tokyo');
      expect(TimezoneLocationService.instance.lookup(51.5, -0.13),
          'Europe/London');
    });

    test('lookup misses for points outside both polygons', () {
      // Open ocean somewhere — both fixture polygons exclude this point.
      expect(TimezoneLocationService.instance.lookup(0.0, 0.0), isNull);
      // Just outside the Tokyo bbox.
      expect(TimezoneLocationService.instance.lookup(34.5, 139.5), isNull);
    });
  });

  // The dataset is loaded only by the lookup paths, so its status is read from
  // disk: a downloaded dataset that nothing has loaded yet is still downloaded.
  group('cached dataset status', () {
    late File file;

    setUp(() async {
      await TimezoneLocationService.instance.clear();
      file = File('${(PathProviderPlatform.instance as FakePathProvider).dir.path}'
          '/tz_polygons.geojson');
    });

    test('no file reads as no dataset, whatever the timestamp says', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'tz_polygons_last_updated', '2026-08-23T21:41:17.000');
      expect(await TimezoneLocationService.instance.hasCachedDataset(), isFalse);
      expect(await TimezoneLocationService.instance.cachedZoneCount(), isNull);
    });

    test('a stored count is reported without loading the dataset', () async {
      await file.writeAsString(_fixture);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('tz_polygons_zone_count', 2);
      expect(await TimezoneLocationService.instance.hasCachedDataset(), isTrue);
      expect(await TimezoneLocationService.instance.cachedZoneCount(), 2);
      expect(TimezoneLocationService.instance.isReady, isFalse);
      expect(TimezoneLocationService.instance.zoneCount, 0);
    });

    test('a dataset stored before the count is counted once, not loaded',
        () async {
      await file.writeAsString(_fixture);
      expect(await TimezoneLocationService.instance.cachedZoneCount(), 2);
      expect(TimezoneLocationService.instance.isReady, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('tz_polygons_zone_count'), 2);
    });

    test('loading from cache stores the count; clear removes it', () async {
      await file.writeAsString(_fixture);
      expect(await TimezoneLocationService.instance.loadFromCacheIfPresent(),
          isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('tz_polygons_zone_count'), 2);

      await TimezoneLocationService.instance.clear();
      expect(prefs.getInt('tz_polygons_zone_count'), isNull);
      expect(await TimezoneLocationService.instance.cachedZoneCount(), isNull);
    });
  });
}
