import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/foreground_poll_engine.dart';

void main() {
  group('ForegroundPollEngine.indicesToRefresh', () {
    test('returns empty when no sites are polled', () {
      final result = ForegroundPollEngine.indicesToRefresh(
        siteCount: 3,
        currentIndex: 0,
        loadedIndices: {0, 1, 2},
        isPolled: (_) => false,
      );
      expect(result, isEmpty);
    });

    test('excludes the current active site', () {
      final result = ForegroundPollEngine.indicesToRefresh(
        siteCount: 3,
        currentIndex: 1,
        loadedIndices: {0, 1, 2},
        isPolled: (_) => true,
      );
      expect(result, [0, 2]);
    });

    test('excludes unloaded sites', () {
      final result = ForegroundPollEngine.indicesToRefresh(
        siteCount: 4,
        currentIndex: 0,
        loadedIndices: {0, 2},
        isPolled: (_) => true,
      );
      expect(result, [2]);
    });

    test('returns all loaded polled sites except current', () {
      final polledSet = {1, 3};
      final result = ForegroundPollEngine.indicesToRefresh(
        siteCount: 5,
        currentIndex: 0,
        loadedIndices: {0, 1, 2, 3, 4},
        isPolled: (i) => polledSet.contains(i),
      );
      expect(result, [1, 3]);
    });

    test('handles null currentIndex', () {
      final result = ForegroundPollEngine.indicesToRefresh(
        siteCount: 2,
        currentIndex: null,
        loadedIndices: {0, 1},
        isPolled: (_) => true,
      );
      expect(result, [0, 1]);
    });
  });
}
