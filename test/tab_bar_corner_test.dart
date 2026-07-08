import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/tab_bar_corner.dart';

void main() {
  group('tabBarCornerNearest', () {
    test('picks the quadrant the button center sits in', () {
      expect(tabBarCornerNearest(-0.4, -0.9), TabBarCorner.topLeft);
      expect(tabBarCornerNearest(0.7, -0.1), TabBarCorner.topRight);
      expect(tabBarCornerNearest(-1, 1), TabBarCorner.bottomLeft);
      expect(tabBarCornerNearest(0.2, 0.3), TabBarCorner.bottomRight);
    });

    test('dead center resolves to bottom-left, matching axis defaults', () {
      expect(tabBarCornerNearest(0, 0), TabBarCorner.bottomLeft);
    });
  });

  group('tabBarCornerDragFraction', () {
    const area = Size(400, 800);

    test('pointer at the padded corners maps to +/-1', () {
      // Button center at margin + size/2 = the -1 anchor on each axis.
      expect(
        tabBarCornerDragFraction(const Offset(37, 37), area,
            buttonSize: 42, margin: 16),
        const Offset(-1, -1),
      );
      expect(
        tabBarCornerDragFraction(const Offset(363, 763), area,
            buttonSize: 42, margin: 16),
        const Offset(1, 1),
      );
    });

    test('pointer in the middle maps to 0', () {
      expect(
        tabBarCornerDragFraction(const Offset(200, 400), area,
            buttonSize: 42, margin: 16),
        const Offset(0, 0),
      );
    });

    test('pointer beyond the edges clamps to +/-1', () {
      expect(
        tabBarCornerDragFraction(const Offset(-50, 900), area,
            buttonSize: 42, margin: 16),
        const Offset(-1, 1),
      );
    });

    test('degenerate area returns center instead of dividing by zero', () {
      expect(
        tabBarCornerDragFraction(const Offset(10, 10), const Size(40, 40),
            buttonSize: 42, margin: 16),
        const Offset(0, 0),
      );
    });
  });

  group('tabBarCornerFromName', () {
    test('round-trips every corner and rejects unknown names', () {
      for (final corner in TabBarCorner.values) {
        expect(tabBarCornerFromName(corner.name), corner);
      }
      expect(tabBarCornerFromName(null), isNull);
      expect(tabBarCornerFromName('middle'), isNull);
    });
  });

  group('corner axis helpers', () {
    test('right/top predicates', () {
      expect(tabBarCornerIsRight(TabBarCorner.topRight), isTrue);
      expect(tabBarCornerIsRight(TabBarCorner.bottomRight), isTrue);
      expect(tabBarCornerIsRight(TabBarCorner.topLeft), isFalse);
      expect(tabBarCornerIsRight(TabBarCorner.bottomLeft), isFalse);
      expect(tabBarCornerIsTop(TabBarCorner.topLeft), isTrue);
      expect(tabBarCornerIsTop(TabBarCorner.topRight), isTrue);
      expect(tabBarCornerIsTop(TabBarCorner.bottomLeft), isFalse);
      expect(tabBarCornerIsTop(TabBarCorner.bottomRight), isFalse);
    });
  });
}
