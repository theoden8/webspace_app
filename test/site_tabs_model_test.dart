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
        ..remove('tabs')
        ..remove('activeTabId');
      final m = WebViewModel.fromJson(json, null);
      expect(m.tabs, hasLength(1));
      expect(m.activeTabId, kPrimaryTabId);
      expect(m.currentUrl, 'https://github.com/notifications');
      expect(m.pageTitle, 'Notifications');
      // …and serialising it again omits the list entirely, so on-disk output
      // is unchanged for a user who never opened a second tab.
      expect(m.toJson().containsKey('tabs'), isFalse);
      expect(m.toJson().containsKey('activeTabId'), isFalse);
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

      final back = WebViewModel.fromJson(m.toJson(), null);
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

      final back = WebViewModel.fromJson(m.toJson(), null);
      expect(back.activeTabId, child.id);
      expect(back.currentUrl, 'https://github.com/pulls');
    });

    test('a tab entry that cannot name a tab is dropped, not fatal', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      final json = m.toJson()
        ..['tabs'] = [
          {'id': 'main', 'url': 'https://github.com/'},
          {'id': '../escape', 'url': 'https://evil.test/'},
          {'id': 'ok', 'title': 'no url'},
        ]
        ..['activeTabId'] = 'main';
      final back = WebViewModel.fromJson(json, null);
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
    test('an incognito site serialises no tabs and comes back with one', () {
      final m = WebViewModel(initUrl: 'https://en.wikipedia.org/');
      m.incognito = true;
      m.tabs = [...m.tabs, SiteTab(url: 'https://en.wikipedia.org/wiki/Tab')];
      m.currentUrl = 'https://en.wikipedia.org/wiki/Web_browser';

      final json = m.toJson();
      expect(json.containsKey('tabs'), isFalse);
      expect(json.containsKey('currentUrl'), isFalse);
      final back = WebViewModel.fromJson(json, null);
      expect(back.tabs, hasLength(1));
      expect(back.currentUrl, 'https://en.wikipedia.org/');
    });

    test('an always-open-home site serialises no tabs either', () {
      final m = WebViewModel(initUrl: 'https://mastodon.social/');
      m.alwaysOpenHome = true;
      m.tabs = [...m.tabs, SiteTab(url: 'https://mastodon.social/@a/1')];
      final json = m.toJson();
      expect(json.containsKey('tabs'), isFalse);
      final back = WebViewModel.fromJson(json, null);
      expect(back.tabs, hasLength(1));
      expect(back.currentUrl, 'https://mastodon.social/');
    });

    test('a persisted tab list is ignored on rehydrate for an incognito site',
        () {
      // Defence in depth against JSON written by a build that did not strip.
      final json = WebViewModel(
        siteId: 'abc123',
        initUrl: 'https://en.wikipedia.org/',
        name: 'Wikipedia',
      ).toJson()
        ..['incognito'] = true
        ..['tabs'] = [
          {'id': 'main', 'url': 'https://en.wikipedia.org/'},
          {'id': 'tb', 'url': 'https://en.wikipedia.org/wiki/Secret'},
        ]
        ..['activeTabId'] = 'tb';
      final m = WebViewModel.fromJson(json, null);
      expect(m.tabs, hasLength(1));
      expect(m.currentUrl, 'https://en.wikipedia.org/');
    });
  });
}
