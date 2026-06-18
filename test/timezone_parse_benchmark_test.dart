import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/timezone_location_service.dart';

/// Build a synthetic timezone-boundary GeoJSON at a chosen scale. The real
/// dataset is tens of MB of high-vertex polygons; this approximates the parse
/// shape (jsonDecode + per-vertex Float64List build) deterministically so the
/// cost is measurable in `flutter test`.
String _syntheticGeoJson({required int zones, required int pointsPerRing}) {
  final sb = StringBuffer('{"type":"FeatureCollection","features":[');
  for (var z = 0; z < zones; z++) {
    if (z > 0) sb.write(',');
    final cx = -180.0 + 360.0 * z / zones;
    final cy = (z % 80) - 40.0;
    sb.write('{"type":"Feature","properties":{"tzid":"Etc/Zone$z"},');
    sb.write('"geometry":{"type":"Polygon","coordinates":[[');
    for (var p = 0; p < pointsPerRing; p++) {
      if (p > 0) sb.write(',');
      final ang = 2 * pi * p / pointsPerRing;
      final lng = cx + 0.5 * cos(ang);
      final lat = cy + 0.4 * sin(ang);
      sb.write('[${lng.toStringAsFixed(5)},${lat.toStringAsFixed(5)}]');
    }
    sb.write(']]}}');
  }
  sb.write(']}');
  return sb.toString();
}

void main() {
  // Scale chosen to produce a multi-MB dataset that parses in a measurable
  // (hundreds of ms) window on CI without bloating the run. Bump for a heavier
  // local profile.
  const zones = 200;
  const pointsPerRing = 2000;

  test('timezone parse throughput (benchmark)', () {
    final geojson =
        _syntheticGeoJson(zones: zones, pointsPerRing: pointsPerRing);
    final mb = geojson.length / (1024 * 1024);

    final sw = Stopwatch()..start();
    final count = debugParseZoneCount(geojson);
    sw.stop();

    final pts = zones * pointsPerRing;
    final ms = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('[tz-benchmark] parsed $count zones / $pts vertices from '
        '${mb.toStringAsFixed(1)}MB in ${ms}ms '
        '(${ms == 0 ? "inf" : (pts / ms).toStringAsFixed(0)} vertices/ms)');

    expect(count, zones);
    // Loose regression ceiling — not a per-machine perf gate. The printed
    // number is the signal to track; this only fails on a gross regression.
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
  });
}
