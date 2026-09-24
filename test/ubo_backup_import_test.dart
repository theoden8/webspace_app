// uBlock Origin backup import (CB-018). The backup shape is uBO's
// `backupUserData`; the fixture below is trimmed from a real one.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/ubo_backup_import.dart';

import 'helpers/user_script_bridge_fakes.dart';

Map<String, dynamic> backupJson({
  List<String>? selected,
  List<String>? whitelist,
  Object? userFilters,
}) =>
    {
      'timeStamp': 1758614400000,
      'version': '1.66.4',
      'userSettings': {'importedLists': []},
      'selectedFilterLists': selected ??
          [
            'user-filters',
            'ublock-filters',
            'easylist',
            'https://lists.example/extra.txt',
            'retired-list',
          ],
      'hiddenSettings': {},
      'whitelist': whitelist ??
          [
            'chrome-extension-scheme',
            'moz-extension-scheme',
            'news.example',
            'https://shop.example/*',
            'https://docs.example/private/page',
            '/^https:\\/\\/.*\\.test\\//',
          ],
      'dynamicFilteringString': 'behind-the-scene * * noop\n'
          'behind-the-scene * 3p noop\n'
          '* * 3p-frame block\n'
          'news.example * 3p-script block',
      'urlFilteringString': '',
      'hostnameSwitchesString': 'no-large-media: behind-the-scene false\n'
          'no-scripting: evil.example true',
      'userFilters': userFilters ??
          ['! my rules', 'forum.example##.promo', '||tracker.example^', ''],
    };

final registry = parseUboAssetRegistry(jsonEncode({
  'assets.json': {
    'content': 'internal',
    'contentURL': ['https://raw.githubusercontent.com/x/assets.json'],
  },
  'ublock-filters': {
    'content': 'filters',
    'title': 'uBlock filters – Ads',
    'contentURL': [
      'https://ublockorigin.github.io/uAssets/filters/filters.txt',
      'assets/ublock/filters.min.txt',
    ],
  },
  'easylist': {
    'content': 'filters',
    'title': 'EasyList',
    'contentURL': ['https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt'],
  },
  'bundled-only': {
    'content': 'filters',
    'contentURL': ['assets/thirdparties/x.txt'],
  },
}));

const existing = [
  ExistingFilterList('easylist', 'https://easylist.to/easylist/easylist.txt'),
  ExistingFilterList('easyprivacy', 'https://easylist.to/easylist/easyprivacy.txt'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsing', () {
    test('a uBO backup parses; anything else does not', () {
      expect(UboBackup.parse(jsonEncode(backupJson())), isNotNull);
      expect(UboBackup.parse('not json'), isNull);
      expect(UboBackup.parse('[]'), isNull);
      expect(
          UboBackup.parse(jsonEncode({'sites': [], 'webspaces': []})), isNull,
          reason: 'a WebSpace settings backup is not a uBO backup');
      final noSettings = backupJson()..remove('userSettings');
      expect(UboBackup.parse(jsonEncode(noSettings)), isNull);
    });

    test('only rules beyond uBO defaults count as dropped', () {
      final b = UboBackup.parse(jsonEncode(backupJson()))!;
      expect(b.dynamicRuleCount, 2);
      expect(b.switchRuleCount, 1);
      expect(b.urlRuleCount, 0);
    });

    test('older backups: string whitelist, filterLists map, string filters',
        () {
      final b = UboBackup.parse(jsonEncode({
        'userSettings': {},
        'netWhitelist': 'a.example\nb.example',
        'filterLists': {
          'easylist': {'off': false},
          'easyprivacy': {'off': true},
        },
        'externalLists': 'https://lists.example/old.txt',
        'userFilters': '||x.example^\n',
      }))!;
      expect(b.selectedLists, ['easylist', 'https://lists.example/old.txt']);
      expect(b.trustedDirectives, ['a.example', 'b.example']);
      expect(b.userFilters, '||x.example^');
    });
  });

  group('planning', () {
    final plan = planUboImport(UboBackup.parse(jsonEncode(backupJson()))!,
        existing: existing, registry: registry);

    test('a key the app already has enables it instead of adding a mirror',
        () {
      expect(plan.enableIds, ['easylist']);
      expect(plan.addLists.map((l) => l.url), isNot(contains(contains('uAssets/thirdparties/easylist'))));
    });

    test('keys resolve through the registry, URLs are taken as they are', () {
      expect(plan.addLists.map((l) => (l.name, l.url)), [
        ('uBlock filters – Ads',
            'https://ublockorigin.github.io/uAssets/filters/filters.txt'),
        ('extra.txt', 'https://lists.example/extra.txt'),
      ]);
      expect(plan.unresolvedKeys, ['retired-list']);
    });

    test('own filters come over with their enabled state', () {
      expect(plan.userFilters, '! my rules\nforum.example##.promo\n||tracker.example^');
      expect(plan.userFiltersEnabled, isTrue);
      final off = planUboImport(
          UboBackup.parse(jsonEncode(backupJson(selected: ['easylist'])))!,
          existing: existing,
          registry: registry);
      expect(off.userFiltersEnabled, isFalse);
    });

    test('only whole-host trust becomes a per-site switch', () {
      expect(plan.trustedHosts, {'news.example', 'shop.example'});
      expect(plan.unsupportedTrusted, [
        'https://docs.example/private/page',
        '/^https:\\/\\/.*\\.test\\//',
      ]);
    });

    test('without the registry, only keys the app has still resolve', () {
      final offline = planUboImport(UboBackup.parse(jsonEncode(backupJson()))!,
          existing: existing, registry: const {});
      expect(offline.enableIds, ['easylist']);
      expect(offline.unresolvedKeys, ['ublock-filters', 'retired-list']);
    });

    test('a trusted host covers its subdomains, not look-alikes', () {
      expect(hostTrustedBy('news.example', {'news.example'}), isTrue);
      expect(hostTrustedBy('www.news.example', {'news.example'}), isTrue);
      expect(hostTrustedBy('fakenews.example', {'news.example'}), isFalse);
    });
  });

  group('applying', () {
    final service = ContentBlockerService.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service.reset();
      service.store = MemoryFileStore();
      service.setLists([
        FilterList(
            id: 'easylist',
            name: 'EasyList',
            url: 'https://easylist.to/easylist/easylist.txt'),
      ]);
    });

    tearDown(resetOutboundHttp);

    test('lists are enabled or added and own filters become a local list',
        () async {
      final plan = planUboImport(UboBackup.parse(jsonEncode(backupJson()))!,
          existing: service.existingForImport, registry: registry);
      final toDownload =
          await service.applyUboImport(plan, userFiltersName: 'uBO: My filters');

      final easylist = service.lists.singleWhere((l) => l.id == 'easylist');
      expect(easylist.enabled, isTrue);
      expect(toDownload, contains('easylist'),
          reason: 'enabled but never downloaded');
      final added = service.lists.where((l) => !l.isLocal && l.id != 'easylist');
      expect(added.map((l) => l.url), [
        'https://ublockorigin.github.io/uAssets/filters/filters.txt',
        'https://lists.example/extra.txt',
      ]);
      expect(toDownload, containsAll(added.map((l) => l.id)));
      final mine = service.lists.singleWhere((l) => l.isLocal);
      expect(mine.name, 'uBO: My filters');
      expect(mine.enabled, isTrue);
      expect(service.abpNetworkBlockHosts, contains('tracker.example'));
    });

    test('a second import replaces the own-filters list, no duplicate',
        () async {
      Future<void> importWith(List<String> filters) async {
        final plan = planUboImport(
            UboBackup.parse(jsonEncode(backupJson(userFilters: filters)))!,
            existing: service.existingForImport,
            registry: registry);
        await service.applyUboImport(plan, userFiltersName: 'uBO: My filters');
      }

      await importWith(['||first.example^']);
      await importWith(['||second.example^']);

      final locals = service.lists.where((l) => l.isLocal).toList();
      expect(locals, hasLength(1));
      expect(locals.single.rules, '||second.example^');
      expect(service.lists.where((l) => l.url == 'https://lists.example/extra.txt'),
          hasLength(1));
    });

    test('the registry is fetched through the outbound seam', () async {
      outboundHttp = FakeOutboundFactory((req) => req.url.toString() ==
              kUboAssetRegistryUrl
          ? http.Response(
              jsonEncode({
                'easylist': {
                  'content': 'filters',
                  'title': 'EasyList',
                  'contentURL': ['https://e.example/easylist.txt'],
                }
              }),
              200)
          : http.Response('', 404));
      final fetched = await service.fetchUboAssetRegistry();
      expect(fetched['easylist']?.url, 'https://e.example/easylist.txt');

      outboundHttp = FakeOutboundFactory((_) => http.Response('', 500));
      expect(await service.fetchUboAssetRegistry(), isEmpty);
    });
  });
}
