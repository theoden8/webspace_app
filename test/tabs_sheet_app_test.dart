import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/real_app.dart';

/// TAB-017 through the shipped app. `tabs_sheet_test.dart` hands the sheet
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
    await openWebspace(tester, 'All');
    await openSiteFromDrawer(tester, 'GitHub');
    await tapLink(tester, 'https://duckduckgo.com/?q=webspace');

    final link = appSite('GitHub').tabs.last;
    expect(link.url, 'https://duckduckgo.com/?q=webspace');
    expect(link.hostSiteId, ddg.siteId);
    expect(link.openerSiteId, github.siteId);

    await openSiteFromDrawer(tester, 'DuckDuckGo');
    await openTabsSheet(tester);
    expect(find.text('In GitHub'), findsOneWidget);
    expect(find.text('https://duckduckgo.com/?q=webspace'), findsOneWidget);
  });

  testWidgets('with GitHub\'s routing off the tab is GitHub\'s own',
      (tester) async {
    await pumpRealApp(tester, sites: [github, ddg]);
    await openWebspace(tester, 'All');
    await openSiteFromDrawer(tester, 'GitHub');
    await tapLink(tester, 'https://duckduckgo.com/?q=webspace');

    final link = appSite('GitHub').tabs.last;
    expect(link.hostSiteId, isNull);
    expect(link.openerSiteId, github.siteId);

    await openSiteFromDrawer(tester, 'DuckDuckGo');
    await openTabsSheet(tester);
    expect(find.text('In GitHub'), findsNothing);
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
    await openWebspace(tester, 'Search');
    await openSiteFromDrawer(tester, 'DuckDuckGo');
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
}
