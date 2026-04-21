import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_lifecycle_engine.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  group('SiteLifecycleEngine.computeDeletionPatch', () {
    test('drops deleted index and shifts greater indices down in loadedIndices', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 2,
        siteCountBeforeRemoval: 5,
        loadedIndices: {0, 2, 3, 4},
        webspaces: const [],
        currentIndex: null,
      );

      expect(patch.newLoadedIndices, {0, 2, 3});
    });

    test('is idempotent when caller already removed deletedIndex from loadedIndices', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 2,
        siteCountBeforeRemoval: 5,
        loadedIndices: {0, 3, 4},
        webspaces: const [],
        currentIndex: null,
      );

      expect(patch.newLoadedIndices, {0, 2, 3});
    });

    test('filters loadedIndices that would be out of bounds after removal', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 0,
        siteCountBeforeRemoval: 2,
        loadedIndices: {0, 1, 99},
        webspaces: const [],
        currentIndex: null,
      );

      expect(patch.newLoadedIndices, {0});
    });

    test('drops deleted index from webspace siteIndices and shifts larger ones down', () {
      final ws = Webspace(id: 'w1', name: 'Work', siteIndices: [0, 2, 3]);
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 2,
        siteCountBeforeRemoval: 5,
        loadedIndices: const {},
        webspaces: [ws],
        currentIndex: null,
      );

      expect(patch.newSiteIndicesByWebspaceId['w1'], [0, 2]);
    });

    test('leaves webspace entries absent from map when unchanged', () {
      final ws = Webspace(id: 'w1', name: 'Work', siteIndices: [0, 1]);
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 4,
        siteCountBeforeRemoval: 5,
        loadedIndices: const {},
        webspaces: [ws],
        currentIndex: null,
      );

      expect(patch.newSiteIndicesByWebspaceId.containsKey('w1'), isFalse);
    });

    test('deleting a site from multiple webspaces rewrites each', () {
      final ws1 = Webspace(id: 'w1', name: 'A', siteIndices: [0, 1, 2]);
      final ws2 = Webspace(id: 'w2', name: 'B', siteIndices: [1, 2]);
      final ws3 = Webspace(id: 'w3', name: 'C', siteIndices: [3]);
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 1,
        siteCountBeforeRemoval: 4,
        loadedIndices: const {},
        webspaces: [ws1, ws2, ws3],
        currentIndex: null,
      );

      expect(patch.newSiteIndicesByWebspaceId['w1'], [0, 1]);
      expect(patch.newSiteIndicesByWebspaceId['w2'], [1]);
      expect(patch.newSiteIndicesByWebspaceId['w3'], [2]);
    });

    test('strips out-of-bounds webspace indices defensively', () {
      final ws = Webspace(id: 'w1', name: 'A', siteIndices: [0, 99, 1]);
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 0,
        siteCountBeforeRemoval: 2,
        loadedIndices: const {},
        webspaces: [ws],
        currentIndex: null,
      );

      expect(patch.newSiteIndicesByWebspaceId['w1'], [0]);
    });

    test('flags wasCurrentIndex when deleting the active site and clears currentIndex', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 2,
        siteCountBeforeRemoval: 5,
        loadedIndices: const {},
        webspaces: const [],
        currentIndex: 2,
      );

      expect(patch.wasCurrentIndex, isTrue);
      expect(patch.newCurrentIndex, isNull);
    });

    test('shifts currentIndex down when deleting an earlier site', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 1,
        siteCountBeforeRemoval: 5,
        loadedIndices: const {},
        webspaces: const [],
        currentIndex: 3,
      );

      expect(patch.wasCurrentIndex, isFalse);
      expect(patch.newCurrentIndex, 2);
    });

    test('leaves currentIndex unchanged when deleting a later site', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 4,
        siteCountBeforeRemoval: 5,
        loadedIndices: const {},
        webspaces: const [],
        currentIndex: 1,
      );

      expect(patch.wasCurrentIndex, isFalse);
      expect(patch.newCurrentIndex, 1);
    });

    test('leaves currentIndex null when already null', () {
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 0,
        siteCountBeforeRemoval: 1,
        loadedIndices: const {},
        webspaces: const [],
        currentIndex: null,
      );

      expect(patch.wasCurrentIndex, isFalse);
      expect(patch.newCurrentIndex, isNull);
    });

    test('deleting the only site produces empty state', () {
      final ws = Webspace(id: 'w1', name: 'A', siteIndices: [0]);
      final patch = SiteLifecycleEngine.computeDeletionPatch(
        deletedIndex: 0,
        siteCountBeforeRemoval: 1,
        loadedIndices: {0},
        webspaces: [ws],
        currentIndex: 0,
      );

      expect(patch.newLoadedIndices, isEmpty);
      expect(patch.newSiteIndicesByWebspaceId['w1'], isEmpty);
      expect(patch.wasCurrentIndex, isTrue);
      expect(patch.newCurrentIndex, isNull);
    });
  });
}
