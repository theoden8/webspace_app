import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview_state_storage.dart';

void main() {
  group('InMemoryWebViewStateStorage', () {
    late InMemoryWebViewStateStorage storage;

    setUp(() {
      storage = InMemoryWebViewStateStorage();
    });

    test('save and load round-trip', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 42]);
      await storage.saveState('site-a', bytes);
      final loaded = await storage.loadState('site-a');
      expect(loaded, bytes);
    });

    test('load returns null for unknown siteId', () async {
      final loaded = await storage.loadState('does-not-exist');
      expect(loaded, isNull);
    });

    test('overwriting saves replaces the previous bytes', () async {
      await storage.saveState('s', Uint8List.fromList([1]));
      await storage.saveState('s', Uint8List.fromList([2, 3]));
      final loaded = await storage.loadState('s');
      expect(loaded, Uint8List.fromList([2, 3]));
    });

    test('removeState deletes the entry', () async {
      await storage.saveState('s', Uint8List.fromList([1]));
      await storage.removeState('s');
      expect(await storage.loadState('s'), isNull);
    });

    test('removeState on missing siteId is a no-op (does not throw)',
        () async {
      await storage.removeState('does-not-exist');
      // Reach here = no throw.
      expect(await storage.loadState('does-not-exist'), isNull);
    });

    test('removeOrphans keeps active siteIds, removes the rest',
        () async {
      await storage.saveState('a', Uint8List.fromList([1]));
      await storage.saveState('b', Uint8List.fromList([2]));
      await storage.saveState('c', Uint8List.fromList([3]));

      final removed = await storage.removeOrphans({'a', 'c'});
      expect(removed, 1);
      expect(await storage.loadState('a'), isNotNull);
      expect(await storage.loadState('b'), isNull);
      expect(await storage.loadState('c'), isNotNull);
    });

    test('removeOrphans returns 0 when everything is active', () async {
      await storage.saveState('a', Uint8List.fromList([1]));
      final removed = await storage.removeOrphans({'a'});
      expect(removed, 0);
      expect(await storage.loadState('a'), isNotNull);
    });

    test('removeOrphans clears all when activeSiteIds is empty', () async {
      await storage.saveState('a', Uint8List.fromList([1]));
      await storage.saveState('b', Uint8List.fromList([2]));
      final removed = await storage.removeOrphans(const {});
      expect(removed, 2);
      expect(await storage.loadState('a'), isNull);
      expect(await storage.loadState('b'), isNull);
    });

    test('siteIds returns the current set of saved sites', () async {
      await storage.saveState('a', Uint8List.fromList([1]));
      await storage.saveState('b', Uint8List.fromList([2]));
      expect(await storage.siteIds(), {'a', 'b'});
      await storage.removeState('a');
      expect(await storage.siteIds(), {'b'});
    });

    test('saving empty bytes is treated as no-op', () async {
      // Defensive: the platform's saveState() can return null or empty
      // bytes when there's nothing meaningful to save (e.g. a webview
      // that never navigated). We don't store empty entries, so a
      // subsequent load returns null and re-activation falls back to
      // a fresh load instead of attempting an empty restoreState.
      await storage.saveState('s', Uint8List(0));
      expect(await storage.loadState('s'), isNull);
    });
  });
}
