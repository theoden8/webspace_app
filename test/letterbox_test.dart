import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/letterbox.dart';

void main() {
  group('computeLetterboxTarget', () {
    test('snaps a desktop window down to the 200x100 grid', () {
      final t = computeLetterboxTarget(
          availableWidth: 1366, availableHeight: 768);
      // 1366 -> 1200 (6*200), 768 -> 700 (7*100); both within the margin cap.
      expect(t.width, 1200);
      expect(t.height, 700);
    });

    test('exact multiples are unchanged', () {
      final t = computeLetterboxTarget(
          availableWidth: 1200, availableHeight: 800);
      expect(t.width, 1200);
      expect(t.height, 800);
    });

    test('phone width keeps a thin margin instead of collapsing to 200', () {
      // A flat 200-grid floor would trim 390 -> 200 (49% margin). The grid
      // refines so the box stays close to the screen.
      final t = computeLetterboxTarget(
          availableWidth: 390, availableHeight: 844);
      expect(t.width, greaterThanOrEqualTo(390 * (1 - kLetterboxMaxMarginFraction)));
      expect(t.width, lessThanOrEqualTo(390));
    });

    test('two nearby phone widths still collapse onto the same bucket', () {
      final a = computeLetterboxTarget(availableWidth: 405, availableHeight: 850);
      final b = computeLetterboxTarget(availableWidth: 414, availableHeight: 880);
      expect(a.width, 400);
      expect(b.width, 400);
    });

    test('margin stays within the cap across a range of screen sizes', () {
      // Representative phones, tablets, foldables, laptops, desktops, and
      // landscape variants. None may letterbox more than the fraction cap.
      const sizes = <List<double>>[
        [320, 480], [360, 640], [375, 667], [390, 844], [393, 873],
        [402, 874], [414, 896], [428, 926], [430, 932], [360, 780],
        [600, 960], [768, 1024], [810, 1080], [820, 1180], [834, 1194],
        [1024, 768], [1112, 834], [1280, 800], [1366, 768], [1440, 900],
        [1536, 864], [1600, 900], [1920, 1080], [2560, 1440], [3440, 1440],
        // landscape phones / split-screen
        [844, 390], [932, 430], [667, 375], [540, 720], [280, 653],
      ];
      for (final s in sizes) {
        final t = computeLetterboxTarget(
            availableWidth: s[0], availableHeight: s[1]);
        expect(t.width, greaterThan(0), reason: 'w for $s');
        expect(t.height, greaterThan(0), reason: 'h for $s');
        expect(t.width, lessThanOrEqualTo(s[0]), reason: 'w<=avail for $s');
        expect(t.height, lessThanOrEqualTo(s[1]), reason: 'h<=avail for $s');
        expect((s[0] - t.width) / s[0],
            lessThanOrEqualTo(kLetterboxMaxMarginFraction),
            reason: 'w margin for $s');
        expect((s[1] - t.height) / s[1],
            lessThanOrEqualTo(kLetterboxMaxMarginFraction),
            reason: 'h margin for $s');
      }
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
