import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  group('WebspaceSelectionEngine.filteredSiteIndices', () {
    test('returns empty when no webspace is selected', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: null,
        webspaces: [Webspace(id: WebspaceId('w1'), name: 'A', siteIndices: [0, 1])],
        siteCount: 2,
      );
      expect(result, isEmpty);
    });

    test('returns every index for the All webspace (WEBSPACE-009)', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: WebspaceId.all,
        webspaces: const [],
        siteCount: 3,
      );
      expect(result, [0, 1, 2]);
    });

    test('returns empty for All webspace when no sites', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: WebspaceId.all,
        webspaces: const [],
        siteCount: 0,
      );
      expect(result, isEmpty);
    });

    test('returns the webspace siteIndices when selected (WEBSPACE-004)', () {
      final ws = Webspace(id: WebspaceId('w1'), name: 'A', siteIndices: [2, 0, 1]);
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: WebspaceId('w1'),
        webspaces: [ws],
        siteCount: 3,
      );
      expect(result, [2, 0, 1]);
    });

    test('filters out-of-bounds entries without reordering', () {
      final ws = Webspace(id: WebspaceId('w1'), name: 'A', siteIndices: [2, 99, 0, -1, 1]);
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: WebspaceId('w1'),
        webspaces: [ws],
        siteCount: 3,
      );
      expect(result, [2, 0, 1]);
    });

    test('returns empty list for unknown webspace id', () {
      final result = WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: WebspaceId('does-not-exist'),
        webspaces: [Webspace(id: WebspaceId('w1'), name: 'A', siteIndices: [0])],
        siteCount: 1,
      );
      expect(result, isEmpty);
    });
  });

  group('WebspaceSelectionEngine.indicesToResetOnShortcutLaunch', () {
    // HS-007
    test('resets flagged siblings sharing a named webspace with the launched site (AOH-004)', () {
      // Banking webspace: A (launched) and B (flagged); Mail: C (flagged
      // but unrelated). Tap on A's shortcut should reset B, not C.
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: WebspaceId('banking'), name: 'Banking', siteIndices: [0, 1]),
          Webspace(id: WebspaceId('mail'), name: 'Mail', siteIndices: [2]),
        ],
        flag: (i) => i == 1 || i == 2,
      );
      expect(result, {1});
    });

    test('includes the launched site when it satisfies the flag', () {
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: WebspaceId('banking'), name: 'Banking', siteIndices: [0]),
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
          Webspace(id: WebspaceId('mixed'), name: 'Mixed', siteIndices: [0, 1]),
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
          Webspace(id: WebspaceId('banking'), name: 'Banking', siteIndices: [0, 2]),
        ],
        flag: (i) => true,
      );
      expect(result, {0, 2});
    });

    test('returns empty when launchedIndex is negative', () {
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: -1,
        webspaces: [Webspace(id: WebspaceId('w'), name: 'W', siteIndices: [0])],
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
          Webspace(id: WebspaceId('other'), name: 'Other', siteIndices: [1, 2]),
        ],
        flag: (i) => true,
      );
      expect(result, {0});
    });

    test('site in multiple named webspaces resets union of flagged members', () {
      final result = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
        launchedIndex: 0,
        webspaces: [
          Webspace(id: WebspaceId('banking'), name: 'Banking', siteIndices: [0, 1]),
          Webspace(id: WebspaceId('work'), name: 'Work', siteIndices: [0, 2, 3]),
          Webspace(id: WebspaceId('misc'), name: 'Misc', siteIndices: [4]),
        ],
        flag: (i) => i == 1 || i == 3 || i == 4,
      );
      // Misc is unrelated to A, so 4 stays.
      expect(result, {1, 3});
    });
  });

}
