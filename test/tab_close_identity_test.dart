import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

class _Page extends Fake implements TabsHost {
  final calls = <String>[];

  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  Future<void> commitSites(SiteSetChange change) async {}


  @override
  void noteUnloaded(WebViewModel model, {required String why}) =>
      calls.add('unloaded ${model.initUrl} $why');
}

class _ProcessGlobal extends Fake implements ResidencyHost {
  @override
  final ProxyTopology proxyTopology = ProxyTopology.of(
    linux: true,
    android: false,
    routerActive: false,
    sharesDefaultSession: (_) => false,
  );
}

class _NavStates extends Fake implements WebViewStateStorage {
  @override
  Future<Uint8List?> loadState(String key) async => null;

  @override
  Future<void> removeState(String key) async {}
}

void main() {
  tearDown(() => WebViewModel.siteLookup = null);

  test('closing the hosted tab a slot shows releases its identity (LIR-024)',
      () async {
    final owner = WebViewModel(initUrl: 'https://duckduckgo.com/');
    final host = WebViewModel(initUrl: 'https://github.com/');
    WebViewModel.siteLookup = (id) => id == host.siteId ? host : null;
    final hosted = SiteTab(
      url: 'https://github.com/theoden8',
      parentId: owner.activeTabId,
      hostSiteId: host.siteId,
    );
    owner
      ..setTabs([...owner.tabs, hosted])
      ..setActiveTab(hosted.id);
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([owner, host]));
    sites.seed(loaded: [owner, host], shown: host);
    final page = _Page();
    final tabs = TabsController(sites, host: page,
        navStates: _NavStates(), residency: _ProcessGlobal());
    expect(owner.runningIdentity, same(host));

    await tabs.closeTab(owner, tabId: hosted.id);

    expect(owner.runningIdentity, same(owner));
    expect(page.calls, ['unloaded https://duckduckgo.com/ identity change'],
        reason: 'the slot ran as GitHub and now runs as itself, so on a '
            'process-global proxy it rebuilds under its own on next show');
    expect(sites.loaded, {host});
  });

  test('closing the last tab lands on a tab no tab of the site had (TAB-003)',
      () async {
    final site = WebViewModel(initUrl: 'https://example.com/');
    final closed = site.activeTabId;
    final sites = SiteRuntime()
      ..isolation = fakeSharedJar()
      ..applied(SitesLoaded([site]));
    final tabs = TabsController(sites, host: _Page(),
        navStates: _NavStates(), residency: _ProcessGlobal());

    await tabs.closeTab(site, tabId: closed);

    expect(site.tabs, hasLength(1));
    expect(site.activeTabId, isNot(closed),
        reason: 'a capture of the closed tab still in flight would land in '
            'the new tab\'s file');
    expect(site.tabs.single.url, 'https://example.com/');
  });
}
