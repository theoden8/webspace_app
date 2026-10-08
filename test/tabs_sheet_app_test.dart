import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/inappbrowser.dart' show InAppWebViewScreen;
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart';

import 'helpers/real_app.dart';

/// TAB-017 and TAB-019 through the shipped app. `tabs_sheet_test.dart` hands the sheet
/// the sites it lists; here the page state builds that list and the link
/// hook builds the tab, so a gap between them and the sheet fails too.
void main() {
  late WebViewModel github;
  late WebViewModel ddg;

  setUp(() {
    github = WebViewModel(initUrl: 'https://github.com', name: 'GitHub');
    ddg = WebViewModel(initUrl: 'https://duckduckgo.com', name: 'DuckDuckGo');
  });

  testWidgets('a link GitHub routes runs as DuckDuckGo and is in its list',
      (tester) async {
    github.routeOutboundLinks = true;
    await pumpRealApp(tester, sites: [github, ddg]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'GitHub');
    await tapLink(tester, url: 'https://duckduckgo.com/?q=webspace');

    final link = appSite('GitHub').tabs.last;
    expect(link.url, 'https://duckduckgo.com/?q=webspace');
    expect(link.hostSiteId, ddg.siteId);
    expect(link.openerSiteId, github.siteId);

    await openSiteFromDrawer(tester, name: 'DuckDuckGo');
    await openTabsSheet(tester);
    expect(find.text('In GitHub'), findsOneWidget);
    expect(find.text('https://duckduckgo.com/?q=webspace'), findsOneWidget);
  });

  testWidgets('the other way: a GitHub tab under a DuckDuckGo one is in '
      'GitHub\'s list with its parent', (tester) async {
    ddg.routeOutboundLinks = true;
    await pumpRealApp(tester, sites: [github, ddg]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'DuckDuckGo');
    await tapLink(tester, url: 'https://github.com/theoden8/webspace_app');

    final link = appSite('DuckDuckGo').tabs.last;
    expect(link.hostSiteId, github.siteId);
    expect(link.parentId, appSite('DuckDuckGo').tabs.first.id);

    await openSiteFromDrawer(tester, name: 'GitHub');
    await openTabsSheet(tester);
    expect(find.text('In DuckDuckGo'), findsOneWidget);
    expect(find.text('https://duckduckgo.com'), findsOneWidget,
        reason: 'the DuckDuckGo tab the GitHub one was opened from');
    expect(find.text('https://github.com/theoden8/webspace_app'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('https://github.com/theoden8/webspace_app')).dx,
      greaterThan(tester.getTopLeft(find.text('https://duckduckgo.com')).dx),
      reason: 'listed under its parent, not beside it',
    );
  });

  Future<void> typeAddress(WidgetTester tester, {required String url}) async {
    await tester.enterText(find.byType(TextField).first, url);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settleRealApp(tester);
  }

  testWidgets('an address of another site typed in the URL bar opens as a tab '
      'routed like a link', (tester) async {
    github.routeOutboundLinks = true;
    await pumpRealApp(tester, sites: [github, ddg], prefs: {'showUrlBar': true});
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'GitHub');
    await attachWebViews(tester);
    await typeAddress(tester, url: 'https://duckduckgo.com/?q=typed');

    final tab = appSite('GitHub').tabs.last;
    expect(tab.url, 'https://duckduckgo.com/?q=typed');
    expect(tab.hostSiteId, ddg.siteId,
        reason: 'routing on: DuckDuckGo\'s container, not a nested GitHub one');
    expect(appSite('GitHub').activeTabId, tab.id);
    expect(find.byType(InAppWebViewScreen), findsNothing);
  });

  testWidgets('with routing off the typed address is a tab run as GitHub',
      (tester) async {
    await pumpRealApp(tester, sites: [github, ddg], prefs: {'showUrlBar': true});
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'GitHub');
    await attachWebViews(tester);
    await typeAddress(tester, url: 'https://duckduckgo.com/?q=typed');

    final tab = appSite('GitHub').tabs.last;
    expect(tab.url, 'https://duckduckgo.com/?q=typed');
    expect(tab.hostSiteId, isNull);
    expect(tab.openerSiteId, github.siteId);
    expect(find.byType(InAppWebViewScreen), findsNothing);
  });

  testWidgets('the Tabs list closes the keyboard before it opens',
      (tester) async {
    await pumpRealApp(tester, sites: [github, ddg], prefs: {'showUrlBar': true});
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'GitHub');
    await attachWebViews(tester);
    await tester.tap(find.byType(TextField).first);
    await settleRealApp(tester);
    expect(tester.testTextInput.isVisible, isTrue);

    await openTabsSheet(tester);
    expect(tester.testTextInput.isVisible, isFalse,
        reason: 'a sheet under the keyboard cannot be seen');
    expect(find.text('GitHub · 1 tab'), findsOneWidget);
  });

  testWidgets('with GitHub\'s routing off the tab is GitHub\'s own',
      (tester) async {
    await pumpRealApp(tester, sites: [github, ddg]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'GitHub');
    await tapLink(tester, url: 'https://duckduckgo.com/?q=webspace');

    final link = appSite('GitHub').tabs.last;
    expect(link.hostSiteId, isNull);
    expect(link.openerSiteId, github.siteId);

    await openSiteFromDrawer(tester, name: 'DuckDuckGo');
    await openTabsSheet(tester);
    expect(find.text('In GitHub'), findsNothing);
  });

  /// GitHub holding a tab a link opened as DuckDuckGo, and DuckDuckGo with a
  /// search of its own; DuckDuckGo on screen with its Tabs list open.
  Future<SiteTab> onDuckDuckGoWithItsList(WidgetTester tester,
      {List<Webspace> webspaces = const [], String webspace = 'All'}) async {
    github.routeOutboundLinks = true;
    final hosted = SiteTab(
      url: 'https://duckduckgo.com/?q=webspace',
      parentId: github.tabs.single.id,
      hostSiteId: ddg.siteId,
      openerSiteId: github.siteId,
      homeUrl: 'https://duckduckgo.com/?q=webspace',
    );
    github.tabs = [...github.tabs, hosted];
    await pumpRealApp(tester, sites: [github, ddg], webspaces: webspaces);
    await openWebspace(tester, name: webspace);
    await openSiteFromDrawer(tester, name: 'DuckDuckGo');
    await attachWebViews(tester);
    await openTabsSheet(tester);
    return hosted;
  }

  testWidgets('from a tab in GitHub\'s tree the list leads back (TAB-019)',
      (tester) async {
    final hosted = await onDuckDuckGoWithItsList(tester);
    await tester.tap(find.text('https://duckduckgo.com/?q=webspace'));
    await settleRealApp(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('currentIndex'), 0, reason: 'GitHub holds the tab');
    expect(appSite('GitHub').activeTabId, hosted.id);

    await openTabsSheet(tester);
    expect(find.text('GitHub · 2 tabs'), findsOneWidget,
        reason: 'the list is the site on screen\'s, whatever its tab runs as');
    expect(
      tester.getTopLeft(find.text('In DuckDuckGo')).dy,
      greaterThan(
          tester.getTopLeft(find.text('https://duckduckgo.com/?q=webspace')).dy),
      reason: 'GitHub\'s tree, which holds the tab on screen, comes first',
    );
    expect(find.text('duckduckgo.com · where you were'), findsOneWidget);
    await tester.tap(find.text('duckduckgo.com · where you were'));
    await settleRealApp(tester);
    expect(prefs.getInt('currentIndex'), 1, reason: 'back on DuckDuckGo');
    expect(appSite('GitHub').tabs.map((t) => t.id), contains(hosted.id));

    await openTabsSheet(tester);
    expect(find.textContaining('where you were'), findsNothing,
        reason: 'the way back was taken');
  });

  testWidgets('Back at the start of the tab it opened goes back, closing '
      'nothing (TAB-019)', (tester) async {
    final hosted = await onDuckDuckGoWithItsList(
      tester,
      webspaces: [
        Webspace(id: 'ws_search', name: 'Search', siteIds: [ddg.siteId]),
      ],
      webspace: 'Search',
    );
    await tester.tap(find.text('https://duckduckgo.com/?q=webspace'));
    await settleRealApp(tester);
    await attachWebViews(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selectedWebspaceId'), kAllWebspaceId);

    await pressBack(tester);
    expect(prefs.getInt('currentIndex'), 1, reason: 'back on DuckDuckGo');
    expect(prefs.getString('selectedWebspaceId'), 'ws_search',
        reason: 'the webspace the jump left comes back with it');
    expect(appSite('GitHub').tabs.map((t) => t.id), contains(hosted.id),
        reason: 'Back went back instead of closing the tab (TAB-007)');
  });

  testWidgets('GitHub\'s own tab opens from DuckDuckGo\'s list, and its list '
      'leads back', (tester) async {
    await onDuckDuckGoWithItsList(tester);
    await tester.tap(find.text('https://github.com'));
    await settleRealApp(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('currentIndex'), 0);
    expect(appSite('GitHub').activeTabId, github.tabs.first.id);

    await openTabsSheet(tester);
    expect(find.text('GitHub · 2 tabs'), findsOneWidget,
        reason: 'GitHub\'s own tab runs as GitHub, so the list is GitHub\'s');
    expect(find.text('In DuckDuckGo'), findsOneWidget,
        reason: 'nothing there runs as GitHub, but the way back is there');
    await tester.tap(find.text('duckduckgo.com · where you were'));
    await settleRealApp(tester);
    expect(prefs.getInt('currentIndex'), 1, reason: 'back on DuckDuckGo');
  });

  testWidgets('a way to GitHub other than the list leaves the way back behind',
      (tester) async {
    final hosted = await onDuckDuckGoWithItsList(tester);
    await tester.tap(find.text('https://duckduckgo.com/?q=webspace'));
    await settleRealApp(tester);
    await openSiteFromDrawer(tester, name: 'DuckDuckGo');
    await openSiteFromDrawer(tester, name: 'GitHub');
    await attachWebViews(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('currentIndex'), 0);
    expect(appSite('GitHub').activeTabId, hosted.id);

    await pressBack(tester);
    expect(prefs.getInt('currentIndex'), 0,
        reason: 'the drawer went to GitHub, so Back is the tab\'s own again');
    expect(appSite('GitHub').tabs.map((t) => t.id), isNot(contains(hosted.id)),
        reason: 'TAB-007 as before: a tab opened from another closes');
  });

  testWidgets('a webspace without GitHub still lists it; a tap opens GitHub '
      'on the tab under All', (tester) async {
    github.routeOutboundLinks = true;
    final tab = SiteTab(
      url: 'https://duckduckgo.com/?q=webspace',
      parentId: github.tabs.single.id,
      hostSiteId: ddg.siteId,
      openerSiteId: github.siteId,
      homeUrl: 'https://duckduckgo.com/?q=webspace',
    );
    github.tabs = [...github.tabs, tab];
    await pumpRealApp(
      tester,
      sites: [github, ddg],
      webspaces: [
        Webspace(id: 'ws_search', name: 'Search', siteIds: [ddg.siteId]),
      ],
    );
    await openWebspace(tester, name: 'Search');
    await openSiteFromDrawer(tester, name: 'DuckDuckGo');
    await openTabsSheet(tester);
    expect(find.text('All sites'), findsNothing,
        reason: 'the webspace shows one site with tabs');
    expect(find.text('In GitHub'), findsOneWidget);

    await tester.tap(find.text('https://duckduckgo.com/?q=webspace'));
    await settleRealApp(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selectedWebspaceId'), kAllWebspaceId,
        reason: 'GitHub is not in Search (WEBSPACE-012)');
    expect(prefs.getInt('currentIndex'), 0, reason: 'GitHub is on screen');
    expect(appSite('GitHub').activeTabId, tab.id);
  });

  group('races (UI race conditions)', () {
    testWidgets('a double tap on Tabs opens one list', (tester) async {
      await pumpRealApp(tester, sites: [github, ddg]);
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'GitHub');
      await attachWebViews(tester);
      // Two presses in one frame: the second lands while the first is still
      // closing the keyboard, before any sheet is up to take the tap.
      final button = tester.widget<IconButton>(find.ancestor(
          of: find.byTooltip('Tabs'), matching: find.byType(IconButton)));
      button.onPressed!();
      button.onPressed!();
      await settleRealApp(tester);
      expect(find.byType(TabsSheet, skipOffstage: false), findsOneWidget);
    });

    testWidgets('Back twice after a jump goes back once and closes nothing',
        (tester) async {
      final hosted = await onDuckDuckGoWithItsList(tester);
      await tester.tap(find.text('https://duckduckgo.com/?q=webspace'));
      await settleRealApp(tester);
      await attachWebViews(tester);
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.handlePopRoute();
      await tester.binding.handlePopRoute();
      await settleRealApp(tester);
      expect(prefs.getInt('currentIndex'), 1);
      expect(appSite('GitHub').tabs.map((t) => t.id), contains(hosted.id));
      expect(appSite('DuckDuckGo').tabs, hasLength(1),
          reason: 'the second Back found DuckDuckGo at its root: a no-op');
    });

    testWidgets('an address submitted twice opens one tab', (tester) async {
      github.routeOutboundLinks = true;
      await pumpRealApp(tester, sites: [github, ddg], prefs: {'showUrlBar': true});
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'GitHub');
      await attachWebViews(tester);
      await tester.enterText(find.byType(TextField).first, 'https://duckduckgo.com/?q=a');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.enterText(find.byType(TextField).first, 'https://duckduckgo.com/?q=a');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settleRealApp(tester);
      expect(
          appSite('GitHub')
              .tabs
              .where((t) => t.url == 'https://duckduckgo.com/?q=a'),
          hasLength(1));
    });
  });
}
