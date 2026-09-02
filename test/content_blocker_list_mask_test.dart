// Persistence and rebuild behaviour of the per-site filter-list mask
// (CB-015). The mask is derived from the sites and pushed on every save, but
// it is stored so the first engine build of a launch already carries it —
// without that, a masked install reparses every list twice per launch.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentBlockerService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service = ContentBlockerService.instance;
    service.store = MemoryFileStore();
    await service.setListMasks(const {});
  });

  Future<Map<String, dynamic>?> storedMask() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('content_blocker_list_masks');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  group('mask persistence', () {
    test('a mask is stored with its hosts sorted', () async {
      // Three hosts inserted out of order: with two, any reversal of the
      // insertion order is also the sorted order, and the assertion cannot
      // tell a sort from an accident. Stability matters because an unsorted
      // dump would rewrite the prefs blob on every save.
      await service.setListMasks({
        'easylist': {'c.example', 'a.example', 'b.example'},
      });

      expect(await storedMask(), {
        'easylist': ['a.example', 'b.example', 'c.example'],
      });
      expect(service.debugListMasks, {
        'easylist': {'a.example', 'b.example', 'c.example'},
      });
    });

    test('an empty selection is dropped rather than stored', () async {
      await service.setListMasks({
        'easylist': {'a.example'},
        'easyprivacy': <String>{},
      });

      expect(await storedMask(), {
        'easylist': ['a.example'],
      });
      expect(service.debugListMasks.containsKey('easyprivacy'), isFalse);
    });

    test('clearing every mask removes the key', () async {
      await service.setListMasks({
        'easylist': {'a.example'},
      });
      await service.setListMasks(const {});

      expect(await storedMask(), isNull);
      expect(service.debugListMasks, isEmpty);
    });

    test('initialize reads the stored mask back', () async {
      SharedPreferences.setMockInitialValues({
        'content_blocker_list_masks':
            jsonEncode({'easylist': ['a.example', 'b.example']}),
      });
      service.store = MemoryFileStore();

      await service.initialize();

      expect(service.debugListMasks, {
        'easylist': {'a.example', 'b.example'},
      });
    });

    test('a malformed stored mask degrades to none', () async {
      for (final bad in ['not json', '[]', '{"easylist": "a.example"}']) {
        SharedPreferences.setMockInitialValues({
          'content_blocker_list_masks': bad,
        });
        service.store = MemoryFileStore();

        await service.initialize();

        expect(service.debugListMasks.values.expand((h) => h), isEmpty,
            reason: bad);
      }
    });

    test('a stored mask with non-string hosts keeps only the strings',
        () async {
      SharedPreferences.setMockInitialValues({
        'content_blocker_list_masks':
            jsonEncode({'easylist': ['a.example', 7, null]}),
      });
      service.store = MemoryFileStore();

      await service.initialize();

      expect(service.debugListMasks, {
        'easylist': {'a.example'},
      });
    });
  });

  group('rebuild is paid only when the mask moves', () {
    int rebuilds = 0;
    void listener() => rebuilds++;

    setUp(() {
      rebuilds = 0;
      service.addRulesChangedListener(listener);
    });

    tearDown(() {
      service.removeRulesChangedListener(listener);
    });

    test('an unchanged mask does not rebuild', () async {
      await service.setListMasks({
        'easylist': {'a.example'},
      });
      final afterFirst = rebuilds;
      expect(afterFirst, greaterThan(0));

      // Same content, different Set identity and insertion order.
      await service.setListMasks({
        'easylist': {'a.example'},
      });

      expect(rebuilds, afterFirst,
          reason: 'the engine reparses every list, so a no-op must stay one');
    });

    test('adding a host to an existing mask rebuilds', () async {
      await service.setListMasks({
        'easylist': {'a.example'},
      });
      final afterFirst = rebuilds;

      await service.setListMasks({
        'easylist': {'a.example', 'b.example'},
      });

      expect(rebuilds, greaterThan(afterFirst));
    });

    test('swapping which list is masked rebuilds', () async {
      await service.setListMasks({
        'easylist': {'a.example'},
      });
      final afterFirst = rebuilds;

      await service.setListMasks({
        'easyprivacy': {'a.example'},
      });

      expect(rebuilds, greaterThan(afterFirst));
    });
  });
}
