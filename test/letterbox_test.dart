import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/letterbox.dart';

void main() {
  group('computeLetterboxTarget', () {
    test('snaps available area down to the 200x100 grid', () {
      final t = computeLetterboxTarget(
          availableWidth: 1366, availableHeight: 768);
      // 1366 -> 1200 (6*200), 768 -> 700 (7*100).
      expect(t.width, 1200);
      expect(t.height, 700);
    });

    test('exact multiples are unchanged', () {
      final t = computeLetterboxTarget(
          availableWidth: 1200, availableHeight: 800);
      expect(t.width, 1200);
      expect(t.height, 800);
    });

    test('two nearby sizes collapse onto the same bucket', () {
      final a = computeLetterboxTarget(availableWidth: 1300, availableHeight: 740);
      final b = computeLetterboxTarget(availableWidth: 1399, availableHeight: 799);
      expect(a, b);
    });

    test('axis smaller than one grid cell is left as-is', () {
      final t = computeLetterboxTarget(availableWidth: 150, availableHeight: 90);
      expect(t.width, 150);
      expect(t.height, 90);
    });

    test('fixed size is used exactly when it fits', () {
      final t = computeLetterboxTarget(
        availableWidth: 1920,
        availableHeight: 1080,
        fixedWidth: 1024,
        fixedHeight: 768,
      );
      expect(t.width, 1024);
      expect(t.height, 768);
    });

    test('fixed size is capped to the available area', () {
      final t = computeLetterboxTarget(
        availableWidth: 400,
        availableHeight: 800,
        fixedWidth: 1920,
        fixedHeight: 1080,
      );
      expect(t.width, 400);
      expect(t.height, 800);
    });

    test('partial fixed (only width) falls back to the grid', () {
      final t = computeLetterboxTarget(
        availableWidth: 1366,
        availableHeight: 768,
        fixedWidth: 1024,
      );
      expect(t.width, 1200);
      expect(t.height, 700);
    });

    test('infinite or non-positive constraints degrade gracefully', () {
      final inf = computeLetterboxTarget(
          availableWidth: double.infinity, availableHeight: 800);
      expect(inf.width, 0);
      final zero = computeLetterboxTarget(
          availableWidth: 0, availableHeight: 0);
      expect(zero.width, 0);
      expect(zero.height, 0);
    });
  });
}
