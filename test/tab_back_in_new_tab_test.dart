import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_webview_controller.dart';
import 'helpers/model_fixture.dart';

class _Page extends Fake implements TabsHost {
  final offered = <TabId>[];
  var commits = 0;

  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  Future<void> commitSites(SiteSetChange change) async => commits++;

  @override
  void offerOpenTab(WebViewModel model, {required TabId tabId}) =>
      offered.add(tabId);
}

class _NavStates extends Fake implements WebViewStateStorage {}

class _NoResidency extends Fake implements ResidencyHost {}

/// TAB-020: a long press on Back opens the page Back would go to as a parked
/// child of the tab on screen.
void main() {
  tearDown(() => WebViewModel.siteLookup = null);

  ({WebViewModel site, FakeWebViewController webview, _Page page,
      TabsController tabs}) githubOnScreen({bool tabsEnabled = true}) {
    final site = WebViewModel(
        initUrl: 'https://github.com/', tabsEnabled: tabsEnabled)
      ..currentUrl = 'https://github.com/theoden8/webspace_app/pull/601';
    final webview = FakeWebViewController();
    site.controller = webview;
    final sites = SiteRuntime()..applied(SitesLoaded([site]));
    sites.seed(loaded: [site], shown: site);
    final page = _Page();
    final tabs = TabsController(sites,
        host: page, navStates: _NavStates(), residency: _NoResidency());
    return (site: site, webview: webview, page: page, tabs: tabs);
  }

  test('the page Back would go to opens parked under the tab on screen',
      () async {
    final s = githubOnScreen();
    final source = s.site.activeTab;
    s.webview.backEntryAnswer = () async => (
          url: 'https://github.com/theoden8/webspace_app/pulls',
          title: 'Pull requests',
        );

    await s.tabs.openBackInNewTab(s.site);

    expect(s.site.tabs, hasLength(2));
    final child = s.site.tabs.last;
    expect(child.url, 'https://github.com/theoden8/webspace_app/pulls');
    expect(child.title, 'Pull requests');
    expect(child.parentId, source.id);
    expect(s.site.activeTabId, source.id,
        reason: 'the page on screen stays');
    expect(s.webview.calls, ['backEntry'],
        reason: 'no load, no capture: the webview is not touched');
    expect(s.page.offered, [child.id]);
    expect(s.page.commits, 1);
  });

  test('the new tab runs as the tab it came from', () async {
    final s = githubOnScreen();
    final host = WebViewModel(initUrl: 'https://codeberg.org/');
    WebViewModel.siteLookup = (id) => id == host.siteId ? host : null;
    final opener = SiteId.mint();
    final hosted = SiteTab(
      url: 'https://codeberg.org/theoden8/webspace/pulls/2',
      parentId: s.site.activeTabId,
      hostSiteId: host.siteId,
      openerSiteId: opener,
      homeUrl: 'https://codeberg.org/theoden8/webspace',
    );
    s.site
      ..setTabs([...s.site.tabs, hosted])
      ..setActiveTab(hosted.id);
    s.webview.backEntryAnswer = () async =>
        (url: 'https://codeberg.org/theoden8/webspace/pulls', title: null);

    await s.tabs.openBackInNewTab(s.site);

    final child = s.site.tabs.last;
    expect(child.parentId, hosted.id);
    expect(child.hostSiteId, host.siteId);
    expect(child.openerSiteId, opener);
    expect(child.homeUrl, 'https://codeberg.org/theoden8/webspace');
    expect(s.site.activeTabId, hosted.id);
  });

  test('nothing opens at the start of the history', () async {
    final s = githubOnScreen();

    await s.tabs.openBackInNewTab(s.site);

    expect(s.site.tabs, hasLength(1));
    expect(s.page.offered, isEmpty);
    expect(s.page.commits, 0);
  });

  test('a site without tabs does not read its history', () async {
    final s = githubOnScreen(tabsEnabled: false);
    s.webview.backEntryAnswer =
        () async => (url: 'https://github.com/', title: null);

    await s.tabs.openBackInNewTab(s.site);

    expect(s.webview.calls, isEmpty);
    expect(s.site.tabs, hasLength(1));
  });

  test('a tab switch during the read drops the new tab', () async {
    final s = githubOnScreen();
    final other = SiteTab(url: 'https://github.com/notifications');
    s.site.setTabs([...s.site.tabs, other]);
    s.webview.backEntryAnswer = () async {
      // The history read was the tab's that has just been left.
      s.site.setActiveTab(other.id);
      return (url: 'https://github.com/theoden8', title: null);
    };

    await s.tabs.openBackInNewTab(s.site);

    expect(s.site.tabs, hasLength(2));
    expect(s.page.offered, isEmpty);
  });

  group('backEntryIn', () {
    inapp.WebHistory history(List<String> urls, {required int current}) =>
        inapp.WebHistory(currentIndex: current, list: [
          for (final url in urls)
            inapp.WebHistoryItem(url: inapp.WebUri(url), title: ''),
        ]);

    test('reads the entry before the current one', () {
      final h = history(['https://a.test/1', 'https://a.test/2',
          'https://a.test/3', 'https://a.test/4'], current: 2);
      expect(backEntryIn(h, isLinux: false),
          (url: 'https://a.test/2', title: null));
    });

    test('reads the first on Linux, where the back list runs backwards', () {
      // WebKitGTK/WPE order: back list nearest-first, then the current page,
      // then the forward list.
      final h = history(['https://a.test/2', 'https://a.test/1',
          'https://a.test/3', 'https://a.test/4'], current: 2);
      expect(backEntryIn(h, isLinux: true),
          (url: 'https://a.test/2', title: null));
    });

    test('is null at the start, or without a history', () {
      final start = history(['https://a.test/1'], current: 0);
      expect(backEntryIn(start, isLinux: false), isNull);
      expect(backEntryIn(start, isLinux: true), isNull);
      expect(backEntryIn(null, isLinux: false), isNull);
      expect(backEntryIn(inapp.WebHistory(), isLinux: false), isNull);
      expect(backEntryIn(history([], current: 1), isLinux: false), isNull);
    });
  });
}
