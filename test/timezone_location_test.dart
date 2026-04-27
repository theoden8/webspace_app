import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/timezone_location_service.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final Directory _dir;
  _FakePathProvider(this._dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => _dir.path;
  @override
  Future<String?> getTemporaryPath() async => _dir.path;
}

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
    PathProviderPlatform.instance = _FakePathProvider(tmp);
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
          (PathProviderPlatform.instance as _FakePathProvider)._dir.path);
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
}
