import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/opensearch_engine.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_search.dart';
import 'helpers/model_fixture.dart';

/// LIR-018, LIR-022, LIR-023 at the model and engine level, and the per-site
/// search fields of LIR-028 and LIR-031.
void main() {
  late Map<String, WebViewModel> sites;

  WebViewModel add(WebViewModel m) => sites[m.siteId] = m;

  setUp(() {
    sites = {};
    WebViewModel.siteLookup = (id) => sites[id];
  });
  tearDown(() => WebViewModel.siteLookup = null);

  WebViewModel owner({List<SiteTab>? tabs, TabId? active}) => add(WebViewModel(
        siteId: SiteId('gh'),
        initUrl: 'https://github.com/',
        tabs: tabs,
        activeTabId: active,
      ));

  group('SiteTab.hostSiteId', () {
    test('round-trips, and an unsafe id is dropped', () {
      final tab = SiteTab(url: 'https://duckduckgo.com/?q=x', hostSiteId: SiteId('ddg'));
      expect(SiteTab.fromJson(tab.toJson())!.hostSiteId, 'ddg');
      final bad = {...tab.toJson(), 'hostSiteId': '../ddg'};
      expect(SiteTab.fromJson(bad)!.hostSiteId, isNull);
      expect(SiteTab(url: 'https://github.com/').toJson(),
          isNot(contains('hostSiteId')));
    });

    test('a host equal to the owner is the owner', () {
      final m = owner(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        SiteTab(id: TabId('t1'), url: 'https://github.com/x', hostSiteId: SiteId('gh')),
      ]);
      expect(m.tabs[1].hostSiteId, isNull);
    });
  });

  group('running identity (LIR-018)', () {
    test('the active tab\'s host is what the slot runs as', () {
      final ddg = add(WebViewModel(
          siteId: SiteId('ddg'), initUrl: 'https://duckduckgo.com/'));
      final m = owner(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        SiteTab(
            id: TabId('t1'),
            url: 'https://duckduckgo.com/?q=x',
            parentId: kPrimaryTabId,
            hostSiteId: SiteId('ddg')),
      ], active: TabId('t1'));
      expect(identical(m.runningIdentity, ddg), isTrue);
      expect(m.runsHostedTab, isTrue);
      expect(m.activeHostMissing, isFalse);
      m.setActiveTab(kPrimaryTabId);
      expect(identical(m.runningIdentity, m), isTrue);
    });

    test('a missing host never runs the tab as the owner', () {
      final m = owner(tabs: [
        SiteTab(id: TabId('t1'), url: 'https://duckduckgo.com/', hostSiteId: SiteId('gone')),
      ], active: TabId('t1'));
      expect(m.activeHostMissing, isTrue);
    });
  });

  group('persistence (LIR-022)', () {
    test('state bytes are keyed by the identity that made them', () {
      add(WebViewModel(siteId: SiteId('ddg'), initUrl: 'https://duckduckgo.com/'));
      final m = owner(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        SiteTab(id: TabId('t1'), url: 'https://duckduckgo.com/', hostSiteId: SiteId('ddg')),
      ]);
      expect(m.stateKeyForTab(kPrimaryTabId), 'gh.$kPrimaryTabId');
      expect(m.stateKeyForTab(TabId('t1')), 'ddg.t1');
    });

    test('an incognito owner keeps its hosted tabs, not their back stacks (INC-008)', () {
      add(WebViewModel(siteId: SiteId('ddg'), initUrl: 'https://duckduckgo.com/'));
      final m = add(WebViewModel(
        siteId: SiteId('gh'),
        initUrl: 'https://github.com/',
        incognito: true,
        tabs: [
          SiteTab.primary(url: 'https://github.com/'),
          SiteTab(id: TabId('t1'), url: 'https://duckduckgo.com/?q=secret', hostSiteId: SiteId('ddg')),
        ],
        activeTabId: TabId('t1'),
      ));
      expect(m.toJson()['tabs'], hasLength(2));
      expect(m.activeTabPersistsNavState, isFalse);
    });

    test('an Always open Home host adds no condition (TAB-014)', () {
      add(WebViewModel(
          siteId: SiteId('ddg'),
          initUrl: 'https://duckduckgo.com/',
          alwaysOpenHome: true));
      final m = owner(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        SiteTab(id: TabId('t1'), url: 'https://duckduckgo.com/?q=x', hostSiteId: SiteId('ddg')),
      ], active: TabId('t1'));
      final ids = [for (final t in m.toJson()['tabs'] as List) (t as Map)['id']];
      expect(ids, [kPrimaryTabId, 't1']);
      expect(m.activeTabPersistsNavState, isTrue);
    });

    test('an ordinary host persists the tab and its back stack', () {
      add(WebViewModel(siteId: SiteId('ddg'), initUrl: 'https://duckduckgo.com/'));
      final m = owner(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        SiteTab(id: TabId('t1'), url: 'https://duckduckgo.com/?q=x', hostSiteId: SiteId('ddg')),
      ], active: TabId('t1'));
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.tabs.last.hostSiteId, 'ddg');
      expect(back.activeTabId, 't1');
      expect(m.activeTabPersistsNavState, isTrue);
    });
  });

  group('TabLifecycleEngine', () {
    List<SiteTab> tree() => [
          SiteTab.primary(url: 'https://github.com/'),
          SiteTab(id: TabId('h'), url: 'https://duckduckgo.com/', parentId: kPrimaryTabId, hostSiteId: SiteId('ddg')),
          SiteTab(id: TabId('c'), url: 'https://github.com/x', parentId: TabId('h')),
          SiteTab(id: TabId('hh'), url: 'https://duckduckgo.com/2', parentId: TabId('h'), hostSiteId: SiteId('ddg')),
        ];

    test('closeWhere closes a host\'s tabs and re-parents the rest (LIR-023)',
        () {
      final result = TabLifecycleEngine.closeWhere(
          tree(), activeTabId: TabId('hh'), shouldClose: (t) => t.hostSiteId == 'ddg');
      expect(result.closedIds.toSet(), {'h', 'hh'});
      expect(result.tabs.map((t) => t.id), [kPrimaryTabId, 'c']);
      expect(result.tabs.last.parentId, kPrimaryTabId);
      expect(result.activeChanged, isTrue);
    });

    test('ownerRunTab walks up to a tab the owner runs', () {
      final tabs = tree();
      expect(TabLifecycleEngine.ownerRunTab(tabs, activeTabId: TabId('hh')),
          kPrimaryTabId);
      expect(TabLifecycleEngine.ownerRunTab(tabs, activeTabId: TabId('c')), 'c');
      expect(
        TabLifecycleEngine.ownerRunTab(
            [SiteTab(id: TabId('x'), url: 'https://duckduckgo.com/', hostSiteId: SiteId('ddg'))],
            activeTabId: TabId('x')),
        isNull,
      );
    });

    test('ownerRunMove keeps a tab the owner runs, else walks up, else opens '
        'a root tab at home (LIR-018)', () {
      final tabs = tree();
      expect(
          TabLifecycleEngine.ownerRunMove(tabs,
              activeTabId: TabId('c'), homeUrl: 'https://github.com/'),
          isNull);
      final up = TabLifecycleEngine.ownerRunMove(tabs,
          activeTabId: TabId('hh'), homeUrl: 'https://github.com/')!;
      expect(up.active, kPrimaryTabId);
      expect(up.tabs, same(tabs), reason: 'an ancestor adds no tab');
      final hosted = [
        SiteTab(id: TabId('x'), url: 'https://duckduckgo.com/', hostSiteId: SiteId('ddg')),
      ];
      final root = TabLifecycleEngine.ownerRunMove(hosted,
          activeTabId: TabId('x'), homeUrl: 'https://github.com/')!;
      final fresh = root.tabs.singleWhere((t) => t.id == root.active);
      expect(fresh.url, 'https://github.com/');
      expect(fresh.parentId, isNull);
      expect(root.tabs.map((t) => t.id), contains('x'));
    });

    test('a home landing never lands on a hosted tab (TAB-014)', () {
      final hostedHome = SiteTab(
          id: TabId('h'), url: 'https://github.com/', hostSiteId: SiteId('ddg'));
      final tabs = [SiteTab.primary(url: 'https://github.com/x'), hostedHome];
      final parked = TabLifecycleEngine.homeLanding(tabs,
          activeTabId: kPrimaryTabId, initUrl: 'https://github.com/')!;
      expect(parked.activeTabId, isNot('h'));
      expect(parked.tabs, hasLength(3));
      final active = TabLifecycleEngine.homeLanding(tabs,
          activeTabId: TabId('h'), initUrl: 'https://github.com/')!;
      expect(active.activeTabId, isNot('h'));
    });

    test('a site without tabs is sent home on a tab it runs itself', () {
      final m = owner(tabs: [
        SiteTab.primary(url: 'https://github.com/x'),
        SiteTab(
            id: TabId('h'),
            url: 'https://duckduckgo.com/?q=x',
            parentId: kPrimaryTabId,
            hostSiteId: SiteId('ddg')),
      ], active: TabId('h'));
      final landed = WebViewModel.fromJson({
        ...m.toJson(),
        'tabsEnabled': false,
        'alwaysOpenHome': true,
      }, stateSetterF: null);
      expect(landed.activeTabId, kPrimaryTabId);
      expect(landed.currentUrl, 'https://github.com/');
      expect(landed.tabs.last.url, 'https://duckduckgo.com/?q=x');
    });
  });

  group('per-site search fields (LIR-028)', () {
    test('round-trip, omitted at their defaults', () {
      final plain = WebViewModel(siteId: SiteId('a'), initUrl: 'https://a.example/');
      final json = plain.toJson();
      for (final k in ['searchAddress', 'searchesWeb', 'searchSites', 'searchDefault']) {
        expect(json, isNot(contains(k)));
      }
      final set = WebViewModel(
        siteId: SiteId('b'),
        initUrl: 'https://b.example/',
        searchAddress: 'https://b.example/?s=%s',
        searchesWeb: true,
        searchSites: [SiteId('ddg'), SiteId('kagi')],
        searchDefault: SiteId('kagi'),
      );
      final back = WebViewModel.fromJson(set.toJson(), stateSetterF: null);
      expect(back.searchAddress, 'https://b.example/?s=%s');
      expect(back.searchesWeb, isTrue);
      expect(back.searchSites, ['ddg', 'kagi']);
      expect(back.searchDefault, 'kagi');
    });

    test('an import keeps only references to restored sites (LIR-031)', () {
      final plan = planSettingsImport(SettingsBackup(
        version: 1,
        sites: [
          {
            'siteId': 'blog',
            'initUrl': 'https://blog.example/',
            'searchSites': ['ddg', 'not-in-backup'],
            'searchDefault': 'not-in-backup',
          },
          {'siteId': 'ddg', 'initUrl': 'https://duckduckgo.com/'},
        ],
        webspaces: const [],
        themeMode: 0,
        exportedAt: DateTime(2026),
        globalPrefs: {AppPref.webSearchDefaultSite.key: 'not-in-backup'},
      ));
      final blog = plan.sites.firstWhere((s) => s.siteId == 'blog');
      expect(blog.searchSites, ['ddg']);
      expect(blog.searchDefault, isNull);
      expect(plan.appPrefs[AppPref.webSearchDefaultSite.key], '');
    });

    test('wrong types read as absent', () {
      final back = WebViewModel.fromJson({
        'siteId': 'c',
        'initUrl': 'https://c.example/',
        'searchAddress': 42,
        'searchesWeb': 'yes',
        'searchSites': ['ok', 7, '../x'],
        'searchDefault': ['x'],
      }, stateSetterF: null);
      expect(back.searchAddress, isNull);
      expect(back.searchesWeb, isFalse);
      expect(back.searchSites, ['ok']);
      expect(back.searchDefault, isNull);
    });
  });

  group('discovered search (LIR-035)', () {
    const searx = DiscoveredSearch(
        address: 'https://searx.lan/search?q=%s', web: true);

    test('round-trips, omitted until something was found', () {
      final m = WebViewModel(siteId: SiteId('s'), initUrl: 'https://searx.lan/');
      expect(m.toJson(), isNot(contains('discoveredSearchAddress')));
      expect(m.toJson(), isNot(contains('discoveredSearchesWeb')));
      expect(m.searchCapability, isNull);
      expect(m.offerDiscoveredSearch(searx), isTrue);
      expect(m.offerDiscoveredSearch(searx), isFalse,
          reason: 'the same find changes nothing, so nothing is saved');
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.discoveredSearchAddress, 'https://searx.lan/search?q=%s');
      expect(back.discoveredSearchesWeb, isTrue);
      expect(back.searchCapability!.template, 'https://searx.lan/search?q=%s');
    });

    test('an incognito site keeps what it found in memory only', () {
      final m = WebViewModel(
          siteId: SiteId('s'), initUrl: 'https://searx.lan/', incognito: true)
        ..offerDiscoveredSearch(searx);
      expect(m.searchCapability?.template, 'https://searx.lan/search?q=%s');
      final json = m.toJson();
      expect(json, isNot(contains('discoveredSearchAddress')));
      expect(json, isNot(contains('discoveredSearchesWeb')));
    });

    test('wrong types read as absent', () {
      final back = WebViewModel.fromJson({
        'siteId': 's',
        'initUrl': 'https://searx.lan/',
        'discoveredSearchAddress': 7,
        'discoveredSearchesWeb': 'yes',
      }, stateSetterF: null);
      expect(back.discoveredSearchAddress, isNull);
      expect(back.discoveredSearchesWeb, isFalse);
    });
  });
}
