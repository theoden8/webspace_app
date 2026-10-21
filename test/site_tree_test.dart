import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'helpers/localized.dart';

void main() {
  testWidgets(
    'embedded tree opens sites and tabs without dismissing the library',
    (tester) async {
      final root = SiteTab(
        id: TabId('root'),
        url: 'https://alpha.test',
        title: 'Overview',
      );
      final child = SiteTab(
        id: TabId('child'),
        parentId: root.id,
        url: 'https://alpha.test/article',
        title: 'Deep article',
      );
      final alpha = WebViewModel(
        initUrl: root.url,
        name: 'Alpha',
        tabsEnabled: true,
        tabs: [root, child],
        activeTabId: root.id,
      );
      final beta = WebViewModel(
        initUrl: 'https://beta.test',
        name: 'Beta',
        tabsEnabled: false,
        tabs: [
          SiteTab(url: 'https://beta.test/hidden', title: 'Stored hidden tab'),
        ],
      );
      WebViewModel? openedSite;
      TabId? openedTab;
      TabId? closedTab;
      WebViewModel? newTabSite;
      await pumpLocalized(
        tester,
        home: Scaffold(
          body: TabsSheet(
            embedded: true,
            sites: [
              for (final site in [alpha, beta])
                TabsSheetSite(model: site, isCurrent: false, isLoaded: false),
            ],
            currentIndex: -1,
            onOpenSite: (site) => openedSite = site,
            onOpenTab: (site, {required tabId}) {
              openedSite = site;
              openedTab = tabId;
            },
            onNewTab: (site) => newTabSite = site,
            onCloseTab: (_, {required tabId}) => closedTab = tabId,
            onCloseSubtree: (_, {required tabId}) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stored hidden tab'), findsNothing);
      expect(find.text('Beta'), findsOneWidget);
      await tester.tap(find.text('Deep article'));
      expect(openedSite, same(alpha));
      expect(openedTab, child.id);
      expect(find.byType(TabsSheet), findsOneWidget);
      await tester.tap(find.byTooltip('Close tab').first);
      expect(closedTab, root.id);
      expect(find.byType(TabsSheet), findsOneWidget);
      await tester.tap(find.byTooltip('New tab'));
      expect(newTabSite, same(alpha));
      await tester.tap(find.text('Beta'));
      expect(openedSite, same(beta));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tree search reveals a matching child with its ancestors', (
    tester,
  ) async {
    final root = SiteTab(
      id: TabId('root'),
      url: 'https://alpha.test',
      title: 'Overview',
    );
    final child = SiteTab(
      id: TabId('child'),
      parentId: root.id,
      url: 'https://alpha.test/article',
      title: 'Deep article',
    );
    final alpha = WebViewModel(
      initUrl: root.url,
      name: 'Alpha',
      tabsEnabled: true,
      tabs: [root, child],
      activeTabId: root.id,
    );
    Future<void> show(String query) async {
      await pumpLocalized(
        tester,
        home: Scaffold(
          body: TabsSheet(
            embedded: true,
            query: query,
            sites: [
              TabsSheetSite(model: alpha, isCurrent: false, isLoaded: false),
            ],
            currentIndex: -1,
            onOpenSite: (_) {},
            onOpenTab: (_, {required tabId}) {},
            onNewTab: (_) {},
            onCloseTab: (_, {required tabId}) {},
            onCloseSubtree: (_, {required tabId}) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('');
    await tester.tap(
      find
          .descendant(
            of: find.byType(ListTile),
            matching: find.byType(IconButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Deep article'), findsNothing);
    await show('article');
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Deep article'), findsOneWidget);
    await show('missing');
    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Deep article'), findsNothing);
  });
}
