import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/launcher_grid.dart';

const _constraints = SliverConstraints(
  axisDirection: AxisDirection.down,
  growthDirection: GrowthDirection.forward,
  userScrollDirection: ScrollDirection.idle,
  scrollOffset: 0,
  precedingScrollExtent: 0,
  overlap: 0,
  remainingPaintExtent: 600,
  crossAxisExtent: 360,
  crossAxisDirection: AxisDirection.right,
  viewportMainAxisExtent: 600,
  remainingCacheExtent: 600,
  cacheOrigin: 0,
);

const _grid = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 3,
  crossAxisSpacing: 8,
  mainAxisSpacing: 16,
  mainAxisExtent: 150,
);

const _rows = SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 1,
  mainAxisExtent: 60,
);

SliverGridLayout _at(double list) =>
    LauncherMorph(grid: _grid, rows: _rows, list: list).getLayout(_constraints);

void main() {
  test(
    'a grid turning into rows starts as the grid, ends as the rows, and moves each place on a line between (WEBSPACE-015)',
    () {
      final grid = _grid.getLayout(_constraints);
      final rows = _rows.getLayout(_constraints);
      for (var i = 0; i < 10; i++) {
        final a = grid.getGeometryForChildIndex(i);
        final b = rows.getGeometryForChildIndex(i);
        final start = _at(0).getGeometryForChildIndex(i);
        final end = _at(1).getGeometryForChildIndex(i);
        final half = _at(.5).getGeometryForChildIndex(i);
        expect(
          (start.scrollOffset, start.crossAxisOffset, start.crossAxisExtent),
          (a.scrollOffset, a.crossAxisOffset, a.crossAxisExtent),
        );
        expect(
          (end.scrollOffset, end.crossAxisOffset, end.crossAxisExtent),
          (b.scrollOffset, b.crossAxisOffset, b.crossAxisExtent),
        );
        expect(half.scrollOffset, (a.scrollOffset + b.scrollOffset) / 2);
        expect(
          half.crossAxisOffset,
          (a.crossAxisOffset + b.crossAxisOffset) / 2,
        );
        expect(half.mainAxisExtent, (a.mainAxisExtent + b.mainAxisExtent) / 2);
        expect(
          half.crossAxisExtent,
          (a.crossAxisExtent + b.crossAxisExtent) / 2,
        );
      }
      expect(
        _at(.5).computeMaxScrollOffset(10),
        (grid.computeMaxScrollOffset(10) + rows.computeMaxScrollOffset(10)) / 2,
      );
    },
  );

  test(
    'every place in view on the way between is among the places the layout builds',
    () {
      const count = 24;
      for (final list in [.1, .3, .5, .7, .9]) {
        final layout = _at(list);
        for (var top = 0.0; top < 2000; top += 37) {
          final bottom = top + 600;
          final first = layout.getMinChildIndexForScrollOffset(top);
          final last = layout.getMaxChildIndexForScrollOffset(bottom);
          for (var i = 0; i < count; i++) {
            final place = layout.getGeometryForChildIndex(i);
            final inView =
                place.scrollOffset < bottom &&
                place.scrollOffset + place.mainAxisExtent > top;
            if (!inView) continue;
            expect(
              i,
              inInclusiveRange(first, math.max(first, last)),
              reason: 'place $i at $list, view from $top',
            );
          }
        }
      }
    },
  );
}
