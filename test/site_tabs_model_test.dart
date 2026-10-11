import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('TAB-001 — a site owns its tabs', () {
    test('a fresh site has one primary tab at initUrl', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      expect(m.tabs, hasLength(1));
      expect(m.activeTabId, kPrimaryTabId);
      expect(m.activeTab.url, 'https://github.com/');
      expect(m.currentUrl, 'https://github.com/');
      expect(m.tabsAreDefault, isTrue);
    });

    test('currentUrl and pageTitle read and write the active tab', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      m.currentUrl = 'https://github.com/notifications';
      m.pageTitle = 'Notifications';
      expect(m.activeTab.url, 'https://github.com/notifications');
      expect(m.activeTab.title, 'Notifications');

      final second = SiteTab(url: 'https://github.com/pulls');
      m.tabs = [...m.tabs, second];
      m.activeTabId = second.id;
      expect(m.currentUrl, 'https://github.com/pulls');
      expect(m.pageTitle, isNull);
      // Writing now lands on the second tab; the first one is untouched.
      m.currentUrl = 'https://github.com/pulls?q=open';
      expect(m.tabs.first.url, 'https://github.com/notifications');
    });

    test('legacy JSON with currentUrl and no tabs migrates to one tab', () {
      // A site as an older build wrote it: one URL, no tab list.
      final json = WebViewModel(
        siteId: 'abc123',
        initUrl: 'https://github.com/',
        name: 'GitHub',
      ).toJson()
        ..['currentUrl'] = 'https://github.com/notifications'
        ..['pageTitle'] = 'Notifications'
        ..remove('tabs');
      final m = WebViewModel.fromJson(json, stateSetterF: null);
      expect(m.tabs, hasLength(1));
      expect(m.activeTabId, kPrimaryTabId);
      expect(m.currentUrl, 'https://github.com/notifications');
      expect(m.pageTitle, 'Notifications');
      // …and serialising it again omits the list entirely, so on-disk output
      // is unchanged for a user who never opened a second tab.
      expect(m.toJson().containsKey('tabs'), isFalse);
      expect(m.toJson()['currentUrl'], 'https://github.com/notifications');
    });

    test('two tabs round-trip through JSON with their parents intact', () {
      final m = WebViewModel(initUrl: 'https://github.com/', name: 'GitHub');
      final child = SiteTab(
        url: 'https://github.com/pull/601',
        title: 'PR 601',
        parentId: m.activeTabId,
      );
      m.tabs = [...m.tabs, child];

      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.tabs, hasLength(2));
      expect(back.tabs.last.id, child.id);
      expect(back.tabs.last.parentId, kPrimaryTabId);
      expect(back.tabs.last.title, 'PR 601');
      expect(back.activeTabId, m.activeTabId);
      expect(back.tabsAreDefault, isFalse);
    });

    test('the active tab survives the round trip when it is not the first',
        () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      final child = SiteTab(url: 'https://github.com/pulls');
      m.tabs = [...m.tabs, child];
      m.activeTabId = child.id;

      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.activeTabId, child.id);
      expect(back.currentUrl, 'https://github.com/pulls');
    });

    test('the active tab is marked inside the list, not beside it', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      final child = SiteTab(url: 'https://github.com/pulls');
      m.tabs = [...m.tabs, child];
      m.activeTabId = child.id;
      final json = m.toJson();
      expect(json.containsKey('activeTabId'), isFalse);
      final entries = (json['tabs'] as List).cast<Map<String, dynamic>>();
      expect(entries.where((e) => e['active'] == true).map((e) => e['id']),
          [child.id]);
    });

    test('a present tab list wins over the site-level copy of its fields', () {
      // `currentUrl` and `pageTitle` are written beside the list only for
      // builds that predate tabs; an odd or missing copy must not rewrite the
      // tabs it duplicates.
      final m = WebViewModel(initUrl: 'https://github.com/');
      m.pageTitle = 'Home';
      final child = SiteTab(url: 'https://github.com/pulls', title: 'Pulls');
      m.tabs = [...m.tabs, child];
      final json = m.toJson()
        ..['currentUrl'] = 42
        ..remove('pageTitle');
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.tabs.first.title, 'Home');
      expect(back.tabs.last.title, 'Pulls');
      expect(back.currentUrl, 'https://github.com/');
    });

    test('a tab entry with an odd title keeps the tab and the site', () {
      final json = WebViewModel(initUrl: 'https://github.com/').toJson()
        ..['tabs'] = [
          {'id': 'main', 'url': 'https://github.com/', 'title': 7},
          {'id': 'tb', 'url': 'https://github.com/pulls', 'active': true},
        ];
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.tabs.map((t) => t.id), ['main', 'tb']);
      expect(back.tabs.first.title, isNull);
      expect(back.activeTabId, 'tb');
    });

    test('a tab entry that cannot name a tab is dropped, not fatal', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      final json = m.toJson()
        ..['tabs'] = [
          {'id': 'main', 'url': 'https://github.com/'},
          {'id': '../escape', 'url': 'https://evil.test/'},
          {'id': 'ok', 'title': 'no url'},
        ];
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.tabs.map((t) => t.id).toList(), ['main']);
    });
  });

  group('TAB-002 — state keys are per tab', () {
    test('the key is siteId and tabId, separated unambiguously', () {
      final m = WebViewModel(initUrl: 'https://github.com/', siteId: 'site_1');
      expect(m.activeStateKey, 'site_1.main');
      expect(m.stateKeyForTab('t9'), 'site_1.t9');
      // The separator cannot occur inside either half, so "everything this
      // site owns" is a sound prefix match.
      expect(m.activeStateKey.startsWith('${m.siteId}.'), isTrue);
    });

    test('the key follows the active tab', () {
      final m = WebViewModel(initUrl: 'https://github.com/', siteId: 'site_1');
      final second = SiteTab(id: 'tb', url: 'https://github.com/pulls');
      m.tabs = [...m.tabs, second];
      m.activeTabId = 'tb';
      expect(m.activeStateKey, 'site_1.tb');
    });
  });

  group('TAB-009 — tabs under per-site features', () {
    test('an incognito site keeps its tab list, not its URL or cookies', () {
      final m = WebViewModel(initUrl: 'https://en.wikipedia.org/');
      m.incognito = true;
      m.tabs = [...m.tabs, SiteTab(url: 'https://en.wikipedia.org/wiki/Tab')];
      m.currentUrl = 'https://en.wikipedia.org/wiki/Web_browser';

      final json = m.toJson();
      expect(json['tabs'], hasLength(2),
          reason: 'a restart wipes the container, not the tree (TAB-009)');
      expect(json.containsKey('currentUrl'), isFalse);
      expect(json['cookies'], isEmpty);
      final back = WebViewModel.fromJson(json, stateSetterF: null);
      expect(back.tabs.map((t) => t.url),
          ['https://en.wikipedia.org/wiki/Web_browser', 'https://en.wikipedia.org/wiki/Tab']);
      expect(back.activeTabPersistsNavState, isFalse,
          reason: 'its back stacks stay off disk (INC-002)');
    });

    test('an incognito site\'s tab list comes back on rehydrate', () {
      final json = WebViewModel(
        siteId: 'abc123',
        initUrl: 'https://en.wikipedia.org/',
        name: 'Wikipedia',
      ).toJson()
        ..['incognito'] = true
        ..['tabs'] = [
          {'id': 'main', 'url': 'https://en.wikipedia.org/'},
          {'id': 'tb', 'url': 'https://en.wikipedia.org/wiki/Tab', 'active': true},
        ];
      final m = WebViewModel.fromJson(json, stateSetterF: null);
      expect(m.tabs.map((t) => t.id), ['main', 'tb']);
      expect(m.activeTabId, 'tb');
    });
  });

  group('TAB-014 — an always-open-home site lands at home on load', () {
    WebViewModel awayFromHome() {
      final m = WebViewModel(initUrl: 'https://mastodon.social/');
      m.alwaysOpenHome = true;
      m.currentUrl = 'https://mastodon.social/@a/1';
      m.tabs = [...m.tabs, SiteTab(url: 'https://mastodon.social/@b/2')];
      return m;
    }

    test('its tabs reach disk, its currentUrl does not', () {
      final json = awayFromHome().toJson();
      expect(json['tabs'], hasLength(2));
      expect(json.containsKey('currentUrl'), isFalse);
      expect(json.containsKey('pageTitle'), isFalse);
    });

    test('with tabs it opens a new tab at home and keeps the others', () {
      final back =
          WebViewModel.fromJson(awayFromHome().toJson(), stateSetterF: null);
      expect(back.tabs, hasLength(3));
      expect(back.currentUrl, 'https://mastodon.social/');
      expect(back.activeTabId, isNot(kPrimaryTabId));
      expect(back.tabs.map((t) => t.url), contains('https://mastodon.social/@a/1'));
    });

    test('with tabs, a site already at home opens no new tab', () {
      final m = awayFromHome()..currentUrl = 'https://mastodon.social';
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.tabs, hasLength(2));
      expect(back.activeTabId, kPrimaryTabId);
    });

    test('reloading the landed site opens no second home tab', () {
      final once =
          WebViewModel.fromJson(awayFromHome().toJson(), stateSetterF: null);
      final twice = WebViewModel.fromJson(once.toJson(), stateSetterF: null);
      expect(twice.tabs, hasLength(3));
      expect(twice.activeTabId, once.activeTabId);
    });

    test('without tabs the tab it was on is sent home, others are kept', () {
      final m = awayFromHome()..tabsEnabled = false;
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.tabs, hasLength(2));
      expect(back.activeTabId, kPrimaryTabId);
      expect(back.currentUrl, 'https://mastodon.social/');
      expect(back.pageTitle, isNull);
    });

    test('a kiosk site has no tabs, so it is sent home in place', () {
      final m = awayFromHome()..kioskMode = true;
      final back = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(back.tabs, hasLength(2));
      expect(back.currentUrl, 'https://mastodon.social/');
    });

  });
}
