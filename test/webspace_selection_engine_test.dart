import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  group('WebspaceSelectionEngine.filteredSiteIndices', () {
    test('returns empty when no webspace is selected', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: null,
        webspaces: [Webspace(id: 'w1', name: 'A', siteIndices: [0, 1])],
        siteCount: 2,
      );
      expect(result, isEmpty);
    });

    test('returns every index for the All webspace', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: kAllWebspaceId,
        webspaces: const [],
        siteCount: 3,
      );
      expect(result, [0, 1, 2]);
    });

    test('returns empty for All webspace when no sites', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: kAllWebspaceId,
        webspaces: const [],
        siteCount: 0,
      );
      expect(result, isEmpty);
    });

    test('returns the webspace siteIndices when selected', () {
      final ws = Webspace(id: 'w1', name: 'A', siteIndices: [2, 0, 1]);
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: 'w1',
        webspaces: [ws],
        siteCount: 3,
      );
      expect(result, [2, 0, 1]);
    });

    test('filters out-of-bounds entries without reordering', () {
      final ws = Webspace(id: 'w1', name: 'A', siteIndices: [2, 99, 0, -1, 1]);
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: 'w1',
        webspaces: [ws],
        siteCount: 3,
      );
      expect(result, [2, 0, 1]);
    });

    test('returns empty list for unknown webspace id', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: 'does-not-exist',
        webspaces: [Webspace(id: 'w1', name: 'A', siteIndices: [0])],
        siteCount: 1,
      );
      expect(result, isEmpty);
    });
  });

  group('WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch', () {
    test('unloads sites visible only in the previous webspace', () {
      final result = WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
        loadedIndices: {0, 1, 2},
        previousWebspaceIndices: {0, 1},
        newWebspaceIndices: {2, 3},
      );
      expect(result, {0, 1});
    });

    test('preserves sites that appear in both webspaces', () {
      final result = WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
        loadedIndices: {0, 1, 2},
        previousWebspaceIndices: {0, 1, 2},
        newWebspaceIndices: {1, 2, 3},
      );
      expect(result, {0});
    });

    test('unloads nothing when no loaded site was in the previous webspace', () {
      final result = WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
        loadedIndices: {5, 6},
        previousWebspaceIndices: {0, 1},
        newWebspaceIndices: {2, 3},
      );
      expect(result, isEmpty);
    });

    test('does not consider sites not currently loaded', () {
      final result = WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
        loadedIndices: {0},
        previousWebspaceIndices: {0, 1, 2},
        newWebspaceIndices: {3},
      );
      expect(result, {0});
    });

    test('returns empty when switching between identical webspaces', () {
      final result = WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
        loadedIndices: {0, 1},
        previousWebspaceIndices: {0, 1},
        newWebspaceIndices: {0, 1},
      );
      expect(result, isEmpty);
    });
  });

  group('WebspaceSelectionEngine.cleanupWebspaceIndices', () {
    test('strips out-of-bounds indices in place', () {
      final webspaces = [
        Webspace(id: 'w1', name: 'A', siteIndices: [0, 5, 1]),
        Webspace(id: 'w2', name: 'B', siteIndices: [-1, 2, 99]),
      ];
      WebspaceSelectionEngine.cleanupWebspaceIndices(
        webspaces: webspaces,
        siteCount: 3,
      );
      expect(webspaces[0].siteIndices, [0, 1]);
      expect(webspaces[1].siteIndices, [2]);
    });

    test('is a no-op when every index is already in bounds', () {
      final webspaces = [Webspace(id: 'w1', name: 'A', siteIndices: [0, 1, 2])];
      WebspaceSelectionEngine.cleanupWebspaceIndices(
        webspaces: webspaces,
        siteCount: 3,
      );
      expect(webspaces[0].siteIndices, [0, 1, 2]);
    });

    test('empties webspaces when siteCount is zero', () {
      final webspaces = [
        Webspace(id: 'w1', name: 'A', siteIndices: [0, 1, 2]),
        Webspace(id: 'w2', name: 'B', siteIndices: [5]),
      ];
      WebspaceSelectionEngine.cleanupWebspaceIndices(
        webspaces: webspaces,
        siteCount: 0,
      );
      expect(webspaces[0].siteIndices, isEmpty);
      expect(webspaces[1].siteIndices, isEmpty);
    });
  });
}
