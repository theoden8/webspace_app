import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/web_view_model.dart';

/// LIR-034 (a link tab runs as its opener or as the site the link leads to),
/// TAB-017 (a site's list shows its subtrees from other sites' trees) and
/// TAB-018 (container colours), at the model and engine level.
void main() {
  late Map<String, WebViewModel> sites;

  WebViewModel add(WebViewModel m) => sites[m.siteId] = m;

  setUp(() {
    sites = {};
    WebViewModel.siteLookup = (id) => sites[id];
  });
  tearDown(() => WebViewModel.siteLookup = null);

  const ddgLink = 'https://duckduckgo.com/?q=flutter';

  WebViewModel github({List<SiteTab>? tabs, String? active}) => add(
        WebViewModel(
          siteId: 'gh',
          initUrl: 'https://github.com/',
          name: 'GitHub',
          tabs: tabs,
          activeTabId: active,
        ),
      );

  WebViewModel ddg() => add(WebViewModel(
        siteId: 'ddg',
        initUrl: 'https://duckduckgo.com/',
        name: 'DuckDuckGo',
      ));

  /// A link from GitHub's page into DuckDuckGo, opened as a tab of GitHub's
  /// list. [host] is what it runs as: 'ddg' with GitHub's routing on, null
  /// (GitHub itself) with it off.
  SiteTab linkTab({String? host, String id = 'l', String? parent}) => SiteTab(
        id: id,
        url: ddgLink,
        parentId: parent ?? kPrimaryTabId,
        hostSiteId: host,
        openerSiteId: 'gh',
        homeUrl: ddgLink,
      );

  group('SiteTab opener and home (LIR-034)', () {
    test('round-trip, and are omitted when absent', () {
      final tab = linkTab(host: 'ddg');
      final back = SiteTab.fromJson(tab.toJson())!;
      expect(back.openerSiteId, 'gh');
      expect(back.homeUrl, ddgLink);
      expect(back.followsOpener, isTrue);
      final plain = SiteTab(url: 'https://github.com/').toJson();
      expect(plain, isNot(contains('openerSiteId')));
      expect(plain, isNot(contains('homeUrl')));
    });

    test('an opener id that could escape its key is dropped', () {
      for (final bad in ['../gh', 'gh/x', '', 'a b', 42]) {
        final json = {...linkTab().toJson(), 'openerSiteId': bad};
        final back = SiteTab.fromJson(json)!;
        expect(back.openerSiteId, isNull, reason: '$bad');
        expect(back.followsOpener, isFalse);
        expect(back.url, ddgLink, reason: 'the tab itself is kept');
      }
    });

    test('a home that names no web domain is dropped', () {
      for (final bad in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'data:text/html,x',
        'about:blank',
        'https://',
        'duckduckgo.com',
        7,
        null,
      ]) {
        final json = {...linkTab().toJson(), 'homeUrl': bad};
        final back = SiteTab.fromJson(json)!;
        expect(back.homeUrl, isNull, reason: '$bad');
        expect(back.followsOpener, isFalse);
      }
      final http = {...linkTab().toJson(), 'homeUrl': 'http://a.example/x'};
      expect(SiteTab.fromJson(http)!.homeUrl, 'http://a.example/x');
    });

    test('a tab follows its opener only with both fields', () {
      expect(SiteTab(url: ddgLink, openerSiteId: 'gh').followsOpener, isFalse);
      expect(SiteTab(url: ddgLink, homeUrl: ddgLink).followsOpener, isFalse);
      expect(linkTab().followsOpener, isTrue);
    });

    test('the opener survives the site JSON round trip', () {
      ddg();
      final m = github(
        tabs: [SiteTab.primary(url: 'https://github.com/'), linkTab()],
      );
      final back = WebViewModel.fromJson(m.toJson(), null);
      final tab = back.tabs.singleWhere((t) => t.id == 'l');
      expect(tab.openerSiteId, 'gh');
      expect(tab.homeUrl, ddgLink);
      expect(tab.hostSiteId, isNull);
    });
  });

  group('a tab run as its opener (routing off, LIR-034)', () {
    test('runs in the opener\'s container, anchored in the link\'s domain', () {
      ddg();
      final m = github(
        tabs: [SiteTab.primary(url: 'https://github.com/'), linkTab()],
        active: 'l',
      );
      expect(m.runningIdentity, same(m));
      expect(m.runsHostedTab, isFalse);
      expect(m.isForeignTab(m.activeTab), isTrue);
      expect(m.runsForeignTab, isTrue);
      expect(m.navigationHomeUrl, ddgLink);
    });

    test('stays in the link\'s domain and borrows none of the opener\'s claims',
        () {
      ddg();
      final m = github(
        tabs: [SiteTab.primary(url: 'https://github.com/'), linkTab()],
        active: 'l',
      );
      expect(m.navigationMatchesClaim('https://github.com/x'), isFalse);
      NavigationDecision tap(String url) => m.runningIdentity
          .decideUserOpenedLink(url,
              isActive: true,
              homeUrl: m.navigationHomeUrl,
              matchesClaim: m.navigationMatchesClaim);
      expect(tap('https://duckduckgo.com/?q=dart'), NavigationDecision.allow);
      expect(
        tap('https://github.com/flutter'),
        isNot(NavigationDecision.allow),
        reason: 'the opener\'s own pages leave a foreign tab, they do not '
            'load into it',
      );
    });

    test('its state key is the opener\'s, so a flip moves it', () {
      ddg();
      final m = github(
        tabs: [SiteTab.primary(url: 'https://github.com/'), linkTab()],
        active: 'l',
      );
      final asOpener = m.activeStateKey;
      expect(asOpener, webViewStateKey('gh', 'l'));
      m.activeTab.hostSiteId = 'ddg';
      expect(m.activeStateKey, webViewStateKey('ddg', 'l'));
      expect(m.activeStateKey, isNot(asOpener));
    });
  });

  group('a tab run as the link\'s site (routing on, LIR-034)', () {
    test('is a hosted tab in its own domain, not a foreign one', () {
      final d = ddg();
      final m = github(
        tabs: [SiteTab.primary(url: 'https://github.com/'), linkTab(host: 'ddg')],
        active: 'l',
      );
      expect(m.runningIdentity, same(d));
      expect(m.runsForeignTab, isFalse);
      expect(m.navigationHomeUrl, d.initUrl);
      expect(m.navigationMatchesClaim('https://duckduckgo.com/x'), isTrue);
      expect(m.navigationMatchesClaim('https://github.com/x'), isFalse);
    });

    test('a flip back to the opener makes it foreign again', () {
      ddg();
      final m = github(
        tabs: [SiteTab.primary(url: 'https://github.com/'), linkTab(host: 'ddg')],
        active: 'l',
      );
      m.activeTab.hostSiteId = null;
      expect(m.runningIdentity, same(m));
      expect(m.runsForeignTab, isTrue);
      expect(m.navigationHomeUrl, ddgLink);
    });

    test('a home inside the opener\'s own domain is never foreign', () {
      // A link from a page hosted by GitHub back into GitHub, say: the tab
      // runs as GitHub in GitHub's domain.
      final m = github(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        SiteTab(
          id: 'own',
          url: 'https://github.com/x',
          openerSiteId: 'ddg',
          homeUrl: 'https://github.com/x',
        ),
      ], active: 'own');
      expect(m.runsForeignTab, isFalse);
      expect(m.navigationHomeUrl, m.initUrl);
    });

    test('a tab without a home is never foreign', () {
      final m = github();
      expect(m.isForeignTab(m.activeTab), isFalse);
      expect(m.navigationHomeUrl, m.initUrl);
    });
  });

  group('owner URLs never load into a foreign tab (LIR-018, LIR-034)', () {
    test('ownerRunTab skips foreign tabs up to one the owner runs at home', () {
      ddg();
      final m = github(tabs: [
        SiteTab.primary(url: 'https://github.com/'),
        linkTab(),
        linkTab(id: 'l2', parent: 'l'),
      ], active: 'l2');
      expect(TabLifecycleEngine.ownerRunTab(m.tabs, 'l2'), 'l2',
          reason: 'without the predicate a foreign tab looks owner-run');
      expect(
        TabLifecycleEngine.ownerRunTab(m.tabs, 'l2', isForeign: m.isForeignTab),
        kPrimaryTabId,
      );
    });

    test('bindOwnerRunTab leaves a foreign tab for its owner-run ancestor', () {
      ddg();
      final m = github(tabs: [
        SiteTab.primary(url: 'https://github.com/x'),
        linkTab(),
      ], active: 'l');
      m.bindOwnerRunTab();
      expect(m.activeTabId, kPrimaryTabId);
      expect(m.tabs, hasLength(2));
    });

    test('with no owner-run ancestor it opens a root tab at home', () {
      ddg();
      final m = github(tabs: [
        SiteTab(
          id: 'only',
          url: ddgLink,
          openerSiteId: 'gh',
          homeUrl: ddgLink,
        ),
      ], active: 'only');
      m.bindOwnerRunTab();
      expect(m.activeTabId, isNot('only'));
      expect(m.activeTab.url, m.initUrl);
      expect(m.activeTab.parentId, isNull);
      expect(m.tabs.map((t) => t.id), contains('only'));
    });

    test('a site without tabs is sent home on a tab it runs at home', () {
      ddg();
      final m = github(tabs: [
        SiteTab.primary(url: 'https://github.com/x'),
        linkTab(),
      ], active: 'l');
      m.landAtHome(tabsOn: false);
      expect(m.activeTabId, kPrimaryTabId);
      expect(m.currentUrl, m.initUrl);
      expect(m.tabs.last.url, ddgLink, reason: 'the link tab is kept');
    });
  });

  group('TabLifecycleEngine.subtreesRunningAs (TAB-017)', () {
    // GitHub's tree:
    //   p                       (GitHub)
    //   ├─ a   ddg              root of one subtree
    //   │  ├─ a1 ddg
    //   │  │  └─ a11 gh          kept: it is below a ddg root
    //   │  └─ a2 gh
    //   ├─ b   gh
    //   │  └─ b1 ddg            root of a second subtree
    //   └─ c   other
    List<SiteTab> tree() => [
          SiteTab.primary(url: 'https://github.com/'),
          SiteTab(id: 'a', url: ddgLink, parentId: kPrimaryTabId, hostSiteId: 'ddg'),
          SiteTab(id: 'a1', url: ddgLink, parentId: 'a', hostSiteId: 'ddg'),
          SiteTab(id: 'a11', url: 'https://github.com/1', parentId: 'a1'),
          SiteTab(id: 'a2', url: 'https://github.com/2', parentId: 'a'),
          SiteTab(id: 'b', url: 'https://github.com/b', parentId: kPrimaryTabId),
          SiteTab(id: 'b1', url: ddgLink, parentId: 'b', hostSiteId: 'ddg'),
          SiteTab(id: 'c', url: 'https://x.example/', parentId: kPrimaryTabId, hostSiteId: 'x'),
        ];

    bool asDdg(SiteTab t) => t.hostSiteId == 'ddg';

    test('each subtree comes whole, with its depth restarted at its root', () {
      final rows = TabLifecycleEngine.subtreesRunningAs(tree(), asDdg);
      expect(rows.map((r) => '${r.tab.id}:${r.depth}'),
          ['a:0', 'a1:1', 'a11:2', 'a2:1', 'b1:0']);
      expect(rows.first.childCount, 2);
    });

    test('a site nothing runs as gets no rows', () {
      expect(
        TabLifecycleEngine.subtreesRunningAs(tree(), (t) => t.hostSiteId == 'zz'),
        isEmpty,
      );
    });

    test('a root of the whole tree is a subtree root', () {
      final rows = TabLifecycleEngine.subtreesRunningAs(
          tree(), (t) => t.hostSiteId == null);
      expect(rows.first.tab.id, kPrimaryTabId);
      expect(rows, hasLength(tree().length),
          reason: 'the whole tree hangs off it');
    });

    test('an orphan and a parent cycle still show up', () {
      final tabs = [
        SiteTab(id: 'o', url: ddgLink, parentId: 'gone', hostSiteId: 'ddg'),
        SiteTab(id: 's', url: ddgLink, parentId: 's', hostSiteId: 'ddg'),
        SiteTab(id: 'x', url: ddgLink, parentId: 'y', hostSiteId: 'ddg'),
        SiteTab(id: 'y', url: ddgLink, parentId: 'x', hostSiteId: 'ddg'),
      ];
      final rows = TabLifecycleEngine.subtreesRunningAs(tabs, asDdg);
      expect(rows.map((r) => r.tab.id).toSet(), {'o', 's', 'x', 'y'});
      expect(rows.every((r) => r.depth == 0), isTrue);
    });

    test('the subtree rows are the tree\'s own rows, nothing reordered', () {
      final order = TabLifecycleEngine.treeOrder(tree()).map((r) => r.tab.id);
      final sub = TabLifecycleEngine.subtreesRunningAs(tree(), asDdg)
          .map((r) => r.tab.id)
          .toList();
      expect(order.where(sub.contains).toList(), sub);
    });
  });

  group('ContainerColorEngine (TAB-018)', () {
    test('fills an empty list round the palette', () {
      expect(ContainerColorEngine.assign([null, null, null, null, null], 3),
          [0, 1, 2, 0, 1]);
      expect(ContainerColorEngine.assign([], 8), isEmpty);
    });

    test('keeps every colour already given', () {
      expect(ContainerColorEngine.assign([4, 2, 7], 8), [4, 2, 7]);
    });

    test('gives a new site the least used colour, lowest on a tie', () {
      expect(ContainerColorEngine.assign([0, 0, 1, null], 3), [0, 0, 1, 2]);
      expect(ContainerColorEngine.assign([1, null, 2, null], 3), [1, 0, 2, 0]);
      expect(ContainerColorEngine.assign([0, 1, 2, null], 3), [0, 1, 2, 0]);
    });

    test('counts colours given earlier in the same pass', () {
      expect(ContainerColorEngine.assign([null, 0, null], 2), [1, 0, 0]);
    });

    test('a colour outside the palette counts as none', () {
      expect(ContainerColorEngine.assign([9, -1, null], 3), [0, 1, 2]);
    });

    test('is idempotent', () {
      final once = ContainerColorEngine.assign(
          [null, 3, null, null, 3, null, 0], 4);
      expect(ContainerColorEngine.assign(once, 4), once);
    });

    test('removing or reordering sites changes nobody\'s colour', () {
      final given = ContainerColorEngine.assign(
          List<int?>.filled(6, null), 8);
      final removed = [...given]..removeAt(2);
      expect(ContainerColorEngine.assign(removed, 8), removed);
      final reordered = given.reversed.toList();
      expect(ContainerColorEngine.assign(reordered, 8), reordered);
    });

    test('the fallback is stable, in range and spread', () {
      expect(ContainerColorEngine.fallback('gh', 8),
          ContainerColorEngine.fallback('gh', 8));
      final seen = <int>{};
      for (var i = 0; i < 200; i++) {
        final c = ContainerColorEngine.fallback('site$i', 8);
        expect(c, inInclusiveRange(0, 7));
        seen.add(c);
      }
      expect(seen, hasLength(8));
    });
  });

  group('WebViewModel.containerColor (TAB-018)', () {
    test('round-trips and is omitted until given', () {
      final m = WebViewModel(siteId: 'a', initUrl: 'https://a.example/');
      expect(m.toJson(), isNot(contains('containerColor')));
      m.containerColor = 5;
      expect(WebViewModel.fromJson(m.toJson(), null).containerColor, 5);
    });

    test('a wrong-typed or negative value reads as none, keeping the site', () {
      final base = WebViewModel(siteId: 'a', initUrl: 'https://a.example/')
          .toJson();
      for (final bad in ['3', -1, 2.5, true, <int>[]]) {
        final m = WebViewModel.fromJson({...base, 'containerColor': bad}, null);
        expect(m.containerColor, isNull, reason: '$bad');
        expect(m.siteId, 'a');
      }
    });
  });
}
