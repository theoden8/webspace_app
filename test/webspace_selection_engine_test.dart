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

  group('WebspaceSelectionEngine.indicesToResetOnShortcutLaunch', () {
    test('resets flagged siblings sharing a named webspace with the launched site', () {
      // Banking webspace: A (launched) and B (flagged); Mail: C (flagged
      // but unrelated). Tap on A's shortcut should reset B, not C.
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: 'banking', name: 'Banking', siteIndices: [0, 1]),
          Webspace(id: 'mail', name: 'Mail', siteIndices: [2]),
        ],
        flag: (i) => i == 1 || i == 2,
      );
      expect(result, {1});
    });

    test('includes the launched site when it satisfies the flag', () {
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: 'banking', name: 'Banking', siteIndices: [0]),
        ],
        flag: (i) => true,
      );
      expect(result, {0});
    });

    test('excludes the launched site when its flag is false but resets siblings', () {
      // The launched site itself is unflagged (e.g. user opened a shortcut
      // for a non-banking site that happens to share a webspace with a
      // flagged one). Sibling propagation still runs.
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: 'mixed', name: 'Mixed', siteIndices: [0, 1]),
        ],
        flag: (i) => i == 1,
      );
      expect(result, {1});
    });

    test('skips the synthetic All webspace when computing siblings', () {
      // The launched site lives in "All" and a named webspace; only the
      // named webspace anchors the propagation. Without this, every site
      // in the app would reset on any shortcut tap.
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace.all()..siteIndices = [0, 1, 2, 3],
          Webspace(id: 'banking', name: 'Banking', siteIndices: [0, 2]),
        ],
        flag: (i) => true,
      );
      expect(result, {0, 2});
    });

    test('returns empty when launchedIndex is negative', () {
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: -1,
        webspaces: [Webspace(id: 'w', name: 'W', siteIndices: [0])],
        flag: (i) => true,
      );
      expect(result, isEmpty);
    });

    test('only the launched site resets when it lives only in the All webspace', () {
      // No named webspace contains the launched site, so siblings cannot
      // be inferred. The launched site itself is still anchored — if its
      // flag is true, it resets via its own toJson trip plus this set.
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: 'other', name: 'Other', siteIndices: [1, 2]),
        ],
        flag: (i) => true,
      );
      expect(result, {0});
    });

    test('site in multiple named webspaces resets union of flagged members', () {
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: 'banking', name: 'Banking', siteIndices: [0, 1]),
          Webspace(id: 'work', name: 'Work', siteIndices: [0, 2, 3]),
          Webspace(id: 'misc', name: 'Misc', siteIndices: [4]),
        ],
        flag: (i) => i == 1 || i == 3 || i == 4,
      );
      // Misc is unrelated to A, so 4 stays.
      expect(result, {1, 3});
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
