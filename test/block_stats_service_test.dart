import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BlockStatsService.resetInstanceForTest();
  });

  group('site scope gating (ARCH-006)', () {
    test('a site that never declared its scope contributes nothing', () async {
      final service = BlockStatsService.instance;
      await service.initialize();

      service.record('undeclared-site', BlockCategory.filterList, count: 5);

      expect(service.engine.allTimeTotal, 0);
    });

    test('an app-tier site contributes once declared', () async {
      final service = BlockStatsService.instance;
      await service.initialize();
      service.setSiteContributes('app-site', true);

      service.record('app-site', BlockCategory.filterList, count: 5);

      expect(service.engine.allTimeTotal, 5);
    });

    test('an archive-tier site is ignored and leaves no persisted trace',
        () async {
      final service = BlockStatsService.instance;
      await service.initialize();
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
      await service.initialize();
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
      await first.initialize();
      first.setSiteContributes('site', true);
      first.record('site', BlockCategory.filterList, count: 8);
      first.record('site', BlockCategory.trackingParam, count: 2);
      await first.flush();

      BlockStatsService.resetInstanceForTest();
      final second = BlockStatsService.instance;
      await second.initialize();

      expect(second.engine.allTimeTotal, 10);
      expect(second.engine.allTimeTotals[BlockCategory.trackingParam], 2);
    });

    test('a corrupt stored blob starts from empty instead of crashing',
        () async {
      SharedPreferences.setMockInitialValues({
        BlockStatsService.prefsKey: 'not json at all',
      });

      final service = BlockStatsService.instance;
      await service.initialize();

      expect(service.engine.allTimeTotal, 0);
    });

    test('reset zeroes the persisted payload', () async {
      final service = BlockStatsService.instance;
      await service.initialize();
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
      await service.initialize();
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
      await service.initialize();
      service.setSiteContributes('site', true);
      service.record('site', BlockCategory.dnsBlocklist, count: 3);

      await service.initialize();

      expect(service.engine.allTimeTotal, 3);
    });
  });

  group('session detail (STATS-008)', () {
    test('a label reaches the detail but never the persisted blob', () async {
      final service = BlockStatsService.instance;
      await service.initialize();
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
      await service.initialize();

      service.record('archive-site', BlockCategory.filterList,
          label: 'tracker.example');

      expect(service.detail.isEmpty, isTrue);
    });

    test('reset clears the session detail with the counters', () async {
      final service = BlockStatsService.instance;
      await service.initialize();
      service.setSiteContributes('site', true);
      service.record('site', BlockCategory.localCdn, label: 'cdn.example');

      await service.reset();

      expect(service.engine.allTimeTotal, 0);
      expect(service.detail.isEmpty, isTrue);
    });
  });
}
