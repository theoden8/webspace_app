import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/foreground_poll_engine.dart';

void main() {
  group('ForegroundPollEngine.plan', () {
    test('returns empty when no sites are polled', () {
      final plan = ForegroundPollEngine.plan(
        siteCount: 3,
        currentIndex: 0,
        loadedIndices: {0, 1, 2},
        isPolled: (_) => false,
      );
      expect(plan.reload, isEmpty);
      expect(plan.unloaded, 0);
    });

    test('excludes the current active site', () {
      final plan = ForegroundPollEngine.plan(
        siteCount: 3,
        currentIndex: 1,
        loadedIndices: {0, 1, 2},
        isPolled: (_) => true,
      );
      expect(plan.reload, [0, 2]);
    });

    test('counts polled sites with no webview instead of reloading them', () {
      final plan = ForegroundPollEngine.plan(
        siteCount: 4,
        currentIndex: 0,
        loadedIndices: {0, 2},
        isPolled: (_) => true,
      );
      expect(plan.reload, [2]);
      expect(plan.unloaded, 2);
    });

    test('returns all loaded polled sites except current', () {
      final polledSet = {1, 3};
      final plan = ForegroundPollEngine.plan(
        siteCount: 5,
        currentIndex: 0,
        loadedIndices: {0, 1, 2, 3, 4},
        isPolled: (i) => polledSet.contains(i),
      );
      expect(plan.reload, [1, 3]);
      expect(plan.unloaded, 0);
    });

    test('handles null currentIndex', () {
      final plan = ForegroundPollEngine.plan(
        siteCount: 2,
        currentIndex: null,
        loadedIndices: {0, 1},
        isPolled: (_) => true,
      );
      expect(plan.reload, [0, 1]);
    });
  });
}
