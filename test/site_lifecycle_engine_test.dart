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

  group('SiteLifecycleEngine.computeReorderPatch', () {
    // Ground truth: apply removeAt(old)+insert(new) to a labelled list and
    // read back where each original index landed.
    Map<int, int> groundTruthMapping(int oldIndex, int newIndex, int count) {
      final list = List<int>.generate(count, (i) => i);
      final moved = list.removeAt(oldIndex);
      list.insert(newIndex, moved);
      return {for (var pos = 0; pos < list.length; pos++) list[pos]: pos};
    }

    test('remaps loadedIndices to match removeAt+insert (move forward)', () {
      // [0,1,2,3,4] move 1 -> 3 => [0,2,3,1,4]
      final truth = groundTruthMapping(1, 3, 5);
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 1,
        newIndex: 3,
        loadedIndices: {0, 1, 2, 3, 4},
        currentIndex: null,
      );
      expect(patch.newLoadedIndices, truth.values.toSet());
      expect(patch.newLoadedIndices, {truth[0], truth[1], truth[2], truth[3], truth[4]});
    });

    test('remaps loadedIndices to match removeAt+insert (move backward)', () {
      // [0,1,2,3,4] move 4 -> 0 => [4,0,1,2,3]
      final truth = groundTruthMapping(4, 0, 5);
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 4,
        newIndex: 0,
        loadedIndices: {1, 4},
        currentIndex: null,
      );
      expect(patch.newLoadedIndices, {truth[1], truth[4]});
    });

    test('moved element lands exactly at newIndex', () {
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 2,
        newIndex: 4,
        loadedIndices: {2},
        currentIndex: 2,
      );
      expect(patch.newLoadedIndices, {4});
      expect(patch.newCurrentIndex, 4);
    });

    test('active site pointer follows the move when it is the moved site', () {
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 0,
        newIndex: 3,
        loadedIndices: {0},
        currentIndex: 0,
      );
      expect(patch.newCurrentIndex, 3);
    });

    test('active site pointer shifts when another site moves over it', () {
      // active at 3, move 0 -> 4 => [1,2,3,4,0]; index 3 (site "3") -> pos 2
      final truth = groundTruthMapping(0, 4, 5);
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 0,
        newIndex: 4,
        loadedIndices: const {},
        currentIndex: 3,
      );
      expect(patch.newCurrentIndex, truth[3]);
      expect(patch.newCurrentIndex, 2);
    });

    test('active site pointer unchanged when the move is entirely after it', () {
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 3,
        newIndex: 4,
        loadedIndices: const {},
        currentIndex: 1,
      );
      expect(patch.newCurrentIndex, 1);
    });

    test('null currentIndex stays null', () {
      final patch = SiteLifecycleEngine.computeReorderPatch(
        oldIndex: 1,
        newIndex: 2,
        loadedIndices: const {},
        currentIndex: null,
      );
      expect(patch.newCurrentIndex, isNull);
    });

    test('exhaustive: every index remap matches removeAt+insert ground truth', () {
      const count = 6;
      for (var oldIndex = 0; oldIndex < count; oldIndex++) {
        for (var newIndex = 0; newIndex < count; newIndex++) {
          final truth = groundTruthMapping(oldIndex, newIndex, count);
          final patch = SiteLifecycleEngine.computeReorderPatch(
            oldIndex: oldIndex,
            newIndex: newIndex,
            loadedIndices: {for (var i = 0; i < count; i++) i},
            currentIndex: null,
          );
          for (var i = 0; i < count; i++) {
            final single = SiteLifecycleEngine.computeReorderPatch(
              oldIndex: oldIndex,
              newIndex: newIndex,
              loadedIndices: {i},
              currentIndex: i,
            );
            expect(single.newLoadedIndices, {truth[i]},
                reason: 'move $oldIndex->$newIndex, index $i');
            expect(single.newCurrentIndex, truth[i],
                reason: 'move $oldIndex->$newIndex, currentIndex $i');
          }
          // The full set is a permutation of 0..count-1.
          expect(patch.newLoadedIndices, {for (var i = 0; i < count; i++) i});
        }
      }
    });
  });
}
