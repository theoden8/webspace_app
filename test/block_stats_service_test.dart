import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';

import 'helpers/memory_block_stats_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// One device's encrypted detail blob: shared by every service instance a
  /// test builds, so resetting the singleton models a relaunch rather than a
  /// factory reset.
  late MemoryBlockStatsDetailStore detailStore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BlockStatsService.resetInstanceForTest();
    detailStore = MemoryBlockStatsDetailStore();
  });

  group('site scope gating (ARCH-006)', () {
    test('a site that never declared its scope contributes nothing', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);

      service.record('undeclared-site', BlockCategory.filterList, count: 5);

      expect(service.engine.allTimeTotal, 0);
    });

    test('an app-tier site contributes once declared', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('app-site', true);

      service.record('app-site', BlockCategory.filterList, count: 5);

      expect(service.engine.allTimeTotal, 5);
    });

    test('an archive-tier site is ignored and leaves no persisted trace',
        () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('archive-site', false);

      service.record('archive-site', BlockCategory.filterList, count: 12);
      service.record('archive-site', BlockCategory.dnsBlocklist, count: 3);
      await service.flush();

      final prefs = await SharedPreferences.getInstance();
      expect(service.engine.allTimeTotal, 0);
      expect(prefs.getString(BlockStatsService.prefsKey), isNull);
    });

    test('moving a site into the archive stops its contributions', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('moving-site', true);
      service.record('moving-site', BlockCategory.filterList, count: 2);

      service.setSiteContributes('moving-site', false);
      service.record('moving-site', BlockCategory.filterList, count: 40);

      expect(service.engine.allTimeTotal, 2);
      expect(service.siteContributes('moving-site'), isFalse);
    });
  });

  group('persistence (STATS-002)', () {
    test('counters survive a restart', () async {
      final first = BlockStatsService.instance;
      await first.initialize(detailStore: detailStore);
      first.setSiteContributes('site', true);
      first.record('site', BlockCategory.filterList, count: 8);
      first.record('site', BlockCategory.trackingParam, count: 2);
      await first.flush();

      BlockStatsService.resetInstanceForTest();
      final second = BlockStatsService.instance;
      await second.initialize(detailStore: detailStore);

      expect(second.engine.allTimeTotal, 10);
      expect(second.engine.allTimeTotals[BlockCategory.trackingParam], 2);
    });

    test('a corrupt stored blob starts from empty instead of crashing',
        () async {
      SharedPreferences.setMockInitialValues({
        BlockStatsService.prefsKey: 'not json at all',
      });

      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);

      expect(service.engine.allTimeTotal, 0);
    });

    test('reset zeroes the persisted payload', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('site', true);
      service.record('site', BlockCategory.filterList, count: 4);
      await service.flush();

      await service.reset();

      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString(BlockStatsService.prefsKey)!);
      expect(stored['allTime'], isEmpty);
      expect(stored['days'], isEmpty);
    });

    test('the counters never reach a settings export (STATS-006)', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('site', true);
      service.record('site', BlockCategory.filterList, count: 4242);
      await service.flush();

      final prefs = await SharedPreferences.getInstance();
      final backup = SettingsBackupService.createBackup(
        webViewModels: const [],
        webspaces: const [],
        themeMode: 0,
        globalPrefs: readExportedAppPrefs(prefs),
      );
      final exported = SettingsBackupService.exportToJson(backup);

      expect(kExportedAppPrefs.containsKey(BlockStatsService.prefsKey), isFalse);
      expect(exported, isNot(contains(BlockStatsService.prefsKey)));
      expect(exported, isNot(contains('4242')));
    });

    test('initialize is idempotent and does not discard live counts', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('site', true);
      service.record('site', BlockCategory.dnsBlocklist, count: 3);

      await service.initialize(detailStore: detailStore);

      expect(service.engine.allTimeTotal, 3);
    });
  });

  group('itemised detail (STATS-008)', () {
    test('a label reaches the detail but never the plaintext blob', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('site', true);

      service.record('site', BlockCategory.dnsBlocklist,
          count: 2, label: 'ads.example');
      await service.flush();

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(BlockStatsService.prefsKey)!;
      expect(service.detail.topItems(BlockCategory.dnsBlocklist).single.label,
          'ads.example');
      expect(stored, isNot(contains('ads.example')));
      expect(stored, isNot(contains('site')));
    });

    test('an undeclared site leaves no detail either', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);

      service.record('archive-site', BlockCategory.filterList,
          label: 'tracker.example');

      expect(service.detail.isEmpty, isTrue);
      expect(detailStore.payload, isNull);
    });

    test('reset clears the detail with the counters', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('site', true);
      service.record('site', BlockCategory.localCdn, label: 'cdn.example');

      await service.reset();

      expect(service.engine.allTimeTotal, 0);
      expect(service.detail.isEmpty, isTrue);
    });
  });

  group('detail persistence (STATS-009)', () {
    test('items and per-site counts survive a restart', () async {
      final first = BlockStatsService.instance;
      await first.initialize(detailStore: detailStore);
      first.setSiteContributes('site-a', true);
      first.record('site-a', BlockCategory.dnsBlocklist,
          count: 3, label: 'ads.example');
      first.record('site-a', BlockCategory.dnsBlocklist,
          label: 'beacon.example');
      await first.flush();

      BlockStatsService.resetInstanceForTest();
      final second = BlockStatsService.instance;
      await second.initialize(detailStore: detailStore);

      final items = second.detail.topItems(BlockCategory.dnsBlocklist);
      expect(items.map((i) => i.label).toList(),
          ['ads.example', 'beacon.example']);
      expect(items.first.count, 3);
      expect(second.detail.siteCounts(BlockCategory.dnsBlocklist).single.key,
          'site-a');
    });

    test('a block recorded before the load is folded in, not overwritten',
        () async {
      detailStore.payload = jsonEncode({
        'v': 1,
        'cats': {
          'dns': {
            'items': [
              ['ads.example', 5, DateTime.now().millisecondsSinceEpoch],
            ],
          },
        },
      });

      final service = BlockStatsService.instance;
      service.setSiteContributes('site-a', true);
      final loading = service.initialize(detailStore: detailStore);
      service.record('site-a', BlockCategory.dnsBlocklist,
          label: 'ads.example');
      await loading;

      expect(service.detail.topItems(BlockCategory.dnsBlocklist).single.count,
          6);
    });

    test('a reset is not undone by the next launch', () async {
      final first = BlockStatsService.instance;
      await first.initialize(detailStore: detailStore);
      first.setSiteContributes('site-a', true);
      first.record('site-a', BlockCategory.filterList, label: 'ads.example');
      await first.flush();

      await first.reset();

      BlockStatsService.resetInstanceForTest();
      final second = BlockStatsService.instance;
      await second.initialize(detailStore: detailStore);

      expect(second.detail.isEmpty, isTrue);
    });

    test('a corrupt detail payload costs the items, not the counters',
        () async {
      final first = BlockStatsService.instance;
      await first.initialize(detailStore: detailStore);
      first.setSiteContributes('site-a', true);
      first.record('site-a', BlockCategory.filterList,
          count: 7, label: 'ads.example');
      await first.flush();
      detailStore.payload = 'not json at all';

      BlockStatsService.resetInstanceForTest();
      final second = BlockStatsService.instance;
      await second.initialize(detailStore: detailStore);

      expect(second.engine.allTimeTotal, 7);
      expect(second.detail.isEmpty, isTrue);
    });

    test('a deleted site loses its row on the next orphan sweep', () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('kept', true);
      service.setSiteContributes('deleted', true);
      service.record('kept', BlockCategory.filterList, label: 'ads.example');
      service.record('deleted', BlockCategory.filterList,
          label: 'ads.example');

      await service.removeOrphanedSites({'kept'});

      expect(
          service.detail
              .siteCounts(BlockCategory.filterList)
              .map((e) => e.key)
              .toList(),
          ['kept']);
      // The host it was blocked for is not a site, so it stays counted.
      expect(service.detail.topItems(BlockCategory.filterList).single.count, 2);
      expect(detailStore.payload, isNot(contains('deleted')));
    });

    test('a detail write costs one store write per flush, not one per event',
        () async {
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: detailStore);
      service.setSiteContributes('site-a', true);

      for (var i = 0; i < 50; i++) {
        service.record('site-a', BlockCategory.filterList,
            label: 'ads-$i.example');
      }
      await service.flush();
      await service.flush();

      expect(detailStore.writes, 1);
    });
  });
}
