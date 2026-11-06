import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/recently_closed.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';
import 'helpers/paced_state_storage.dart';

/// TAB-022: a closed tab comes back where it stood, with its history.

class _Page extends Fake implements TabsHost {
  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  Future<void> commitSites(SiteSetChange change) async {}

  @override
  void cancelPendingCapture(SiteId siteId) {}

  @override
  NavCapture? beginNavCapture(WebViewModel site) => null;

  @override
  void noteUnloaded(WebViewModel model, {required String why}) {}
}

class _Residency extends Fake implements ResidencyHost {
  @override
  final ProxyTopology proxyTopology = ProxyTopology.of(
    binding: ProxyBinding.perSite,
    sharesDefaultSession: (_) => false,
  );
}

/// A site whose tabs are [ids], each a child of the one named by [parents]
/// (a root where it names none), the first one active.
WebViewModel siteOf(List<String> ids, {Map<String, String> parents = const {}}) {
  final m = WebViewModel(initUrl: 'https://example.com/', name: 'Example');
  m.setTabs([
    for (final id in ids)
      SiteTab(
        id: id == ids.first ? m.activeTabId : TabId(id),
        url: 'https://example.com/$id',
        title: id,
        parentId: switch (parents[id]) {
          final p? => p == ids.first ? m.activeTabId : TabId(p),
          null => null,
        },
      ),
  ]);
  return m;
}

List<String> titles(WebViewModel m) =>
    [for (final row in TabLifecycleEngine.treeOrder(m.tabs)) '${'  ' * row.depth}${row.tab.title}'];

void main() {
  tearDown(() => WebViewModel.siteLookup = null);

  group('TAB-022 — the engine puts a closed tab back', () {
    test('a tab closed alone returns to its place and takes its children back',
        () {
      final m = siteOf(['a', 'b', 'c', 'd'], parents: {'c': 'b'});
      final before = titles(m);
      final result = TabLifecycleEngine.closeTab(m.tabs,
          activeTabId: m.activeTabId, closeId: TabId('b'));
      final closed =
          TabLifecycleEngine.closedFrom(m.tabs, site: m.siteId, result: result);
      expect(closed.tabs.single.adopt, {TabId('c')});
      m.setTabs(result.tabs);
      expect(titles(m), ['a', 'c', 'd'], reason: 'c moved up as b closed');

      final back = SiteTab(url: closed.first.url, title: closed.first.title);
      m.setTabs(TabLifecycleEngine.reopen(m.tabs, tab: back, closed: closed.tabs.single));
      expect(titles(m), before.map((t) => t).toList()..[1] = 'b',
          reason: 'b is back in its place, c under it again');
      expect(m.tabs.firstWhere((t) => t.title == 'c').parentId, back.id);
    });

    test('a subtree comes back whole, in tree order', () {
      final m = siteOf(['a', 'b', 'c', 'd'], parents: {'c': 'b', 'd': 'c'});
      final result = TabLifecycleEngine.closeSubtree(m.tabs,
          activeTabId: m.activeTabId, closeId: TabId('b'));
      final closed =
          TabLifecycleEngine.closedFrom(m.tabs, site: m.siteId, result: result);
      expect([for (final t in closed.tabs) t.tab.title], ['b', 'c', 'd']);
      expect(closed.tabs.every((t) => t.adopt.isEmpty), isTrue);
    });

    test('a tab whose parent left meanwhile comes back as a root', () {
      final m = siteOf(['a', 'b', 'c'], parents: {'c': 'b'});
      final result = TabLifecycleEngine.closeTab(m.tabs,
          activeTabId: m.activeTabId, closeId: TabId('c'));
      final closed =
          TabLifecycleEngine.closedFrom(m.tabs, site: m.siteId, result: result);
      m.setTabs(result.tabs.where((t) => t.title != 'b').toList());
      final back = SiteTab(
          url: closed.first.url, title: 'c', parentId: closed.first.parentId);
      m.setTabs(TabLifecycleEngine.reopen(m.tabs, tab: back, closed: closed.tabs.single));
      expect(back.parentId, isNull);
      expect(titles(m), ['a', 'c']);
    });
  });

  group('TAB-022 — a close keeps a tab\'s history and a reopen writes it back',
      () {
    late PacedStateStorage files;
    late SiteRuntime sites;
    late TabsController tabs;

    TabsController controllerOver(List<WebViewModel> models) {
      files = PacedStateStorage();
      sites = SiteRuntime()
        ..isolation = fakeContainers()
        ..applied(SitesLoaded(models));
      return TabsController(sites,
          host: _Page(), navStates: files, residency: _Residency());
    }

    test('a closed tab\'s file goes, and its history comes back with it',
        () async {
      final m = siteOf(['a', 'b', 'c'], parents: {'c': 'b'});
      tabs = controllerOver([m]);
      final history = Uint8List.fromList([1, 2, 3]);
      await files.saveState(m.stateKeyForTab(TabId('b')), state: history);

      await tabs.closeTab(m, tabId: TabId('b'));
      expect(files.files, isEmpty, reason: 'no file outlives its tab');
      final closed = tabs.recentlyClosed.latestOf(m.siteId)!;
      expect(closed.tabs.single.history, history);

      final ids = await tabs.reopen(closed);
      final back = m.tabs.firstWhere((t) => t.id == ids[TabId('b')]);
      expect(back.title, 'b');
      expect(titles(m), ['a', 'b', '  c']);
      expect(files.files[m.stateKeyForTab(back.id)], history,
          reason: 'the reopened tab opens on the history it closed with');
      expect(tabs.recentlyClosed.latestOf(m.siteId), isNull,
          reason: 'a close is taken back once');
      expect(await tabs.reopen(closed), isEmpty);
    });

    test('a tab that ran as a site no longer listed comes back as its own',
        () async {
      final owner = siteOf(['a']);
      final host = WebViewModel(initUrl: 'https://github.com/');
      final lookup = {owner.siteId: owner, host.siteId: host};
      WebViewModel.siteLookup = (id) => lookup[id];
      owner.setTabs([
        ...owner.tabs,
        SiteTab(
            id: TabId('b'),
            url: 'https://github.com/b',
            title: 'b',
            hostSiteId: host.siteId),
      ]);
      tabs = controllerOver([owner, host]);
      await tabs.closeTab(owner, tabId: TabId('b'));
      final closed = tabs.recentlyClosed.latestOf(owner.siteId)!;
      expect(closed.first.hostSiteId, host.siteId);

      lookup.remove(host.siteId);
      sites.applied(SiteRemoved(host));
      final ids = await tabs.reopen(closed);
      final back = owner.tabs.firstWhere((t) => t.id == ids[TabId('b')]);
      expect(back.hostSiteId, isNull);
    });

    test('an archive-tier site keeps no close to take back', () async {
      final m = siteOf(['a', 'b']);
      m.isArchiveTier = true;
      tabs = controllerOver([m]);
      await tabs.closeTab(m, tabId: TabId('b'));
      expect(tabs.recentlyClosed.closes, isEmpty,
          reason: 'nothing of an archive\'s sites outlives its close');
    });

    test('the newest closes are kept, at most ten', () async {
      final m = siteOf([for (var i = 0; i < 14; i++) 't$i']);
      tabs = controllerOver([m]);
      for (var i = 1; i < 13; i++) {
        await tabs.closeTab(m, tabId: TabId('t$i'));
      }
      expect(tabs.recentlyClosed.closes, hasLength(10));
      expect(tabs.recentlyClosed.latestOf(m.siteId)!.first.title, 't12');
    });
  });

  test('RecentlyClosed drops the closes of sites that left', () {
    final keep = SiteId('keep');
    final gone = SiteId('gone');
    final list = RecentlyClosed()
      ..push(ClosedTabs(site: gone, tabs: [
        ClosedTab(tab: SiteTab(url: 'https://a/'), index: 0, adopt: const {}),
      ]))
      ..push(ClosedTabs(site: keep, tabs: [
        ClosedTab(tab: SiteTab(url: 'https://b/'), index: 0, adopt: const {}),
      ]));
    list.keepOnly({keep});
    expect([for (final c in list.closes) c.site], [keep]);
  });
}
