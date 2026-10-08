import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/surface_diag_native.dart';

void main() {
  group('SurfaceDiagNative.classify', () {
WindowRegionSample ok(int color, {required double fraction}) =>
    WindowRegionSample(
        status: 'ok', dominantColor: color, uniformFraction: fraction);

    test('uniform white is the BUG-001 fresh-surface fill', () {
      expect(SurfaceDiagNative.classify(ok(0xFFFFFFFF, fraction: 1.0)),
          WindowSampleVerdict.uniformBlank);
      expect(SurfaceDiagNative.classify(ok(0xFFFAFAFA, fraction: 0.99)),
          WindowSampleVerdict.uniformBlank);
    });

    test('uniform black is the BUG-001 re-attach fill', () {
      expect(SurfaceDiagNative.classify(ok(0xFF000000, fraction: 1.0)),
          WindowSampleVerdict.uniformBlank);
      expect(SurfaceDiagNative.classify(ok(0xFF050505, fraction: 0.995)),
          WindowSampleVerdict.uniformBlank);
    });

    test('a uniform colored page is content, not a blank surface', () {
      expect(SurfaceDiagNative.classify(ok(0xFF123524, fraction: 1.0)),
          WindowSampleVerdict.content);
      expect(SurfaceDiagNative.classify(ok(0xFF8C1D5A, fraction: 1.0)),
          WindowSampleVerdict.content);
    });

    test('a non-uniform region is content regardless of dominant color', () {
      expect(SurfaceDiagNative.classify(ok(0xFFFFFFFF, fraction: 0.6)),
          WindowSampleVerdict.content);
    });

    test('failed or unsupported samples are unavailable, never a verdict', () {
      expect(SurfaceDiagNative.classify(WindowRegionSample.unsupported),
          WindowSampleVerdict.unavailable);
      expect(
          SurfaceDiagNative.classify(
              const WindowRegionSample(status: 'copy-failed:1')),
          WindowSampleVerdict.unavailable);
      expect(
          SurfaceDiagNative.classify(
              const WindowRegionSample(status: 'no-surface')),
          WindowSampleVerdict.unavailable);
    });
  });

  group('SurfaceDiagNative.physicalRect', () {
    test('scales by devicePixelRatio and applies the logical inset', () {
      final rect = SurfaceDiagNative.physicalRect(
        logicalRect: const Rect.fromLTWH(10, 20, 100, 200),
        devicePixelRatio: 2.5,
        insetLogical: 4,
      );
      expect(rect.left, (10 + 4) * 2.5);
      expect(rect.top, (20 + 4) * 2.5);
      expect(rect.width, (100 - 8) * 2.5);
      expect(rect.height, (200 - 8) * 2.5);
    });
  });
}
