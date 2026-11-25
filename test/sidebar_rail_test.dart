import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_rail.dart';
import 'package:webspace/widgets/tab_count_pill.dart';

import 'helpers/localized.dart';
import 'helpers/model_fixture.dart';

void main() {
  testWidgets('TAB-032 a tap on the rail\'s empty space expands it; a tap on '
      'a site opens the site', (tester) async {
    var expanded = 0;
    final opened = <String>[];
    final site = WebViewModel(initUrl: 'https://a.test', name: 'A');
    await tester.pumpWidget(localizedApp(Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 500,
          child: SidebarRail(
            sites: [site],
            current: null,
            width: 60,
            onOpen: (s) => opened.add(s.getDisplayName()),
            onOpenTab: (_, {required tabId}) {},
            onExpand: () => expanded++,
            onHide: () {},
          ),
        ),
      ),
    )));
    await tester.tapAt(const Offset(30, 300));
    await tester.pump();
    expect(expanded, 1, reason: 'below the sites there is nothing to tap');

    await tester.tap(find.byTooltip('A'));
    await tester.pump();
    expect(opened, ['A']);
    expect(expanded, 1, reason: 'a site\'s tap is the site\'s');
  });

  testWidgets('TAB-032 a rail site\'s tab count sits over its square\'s '
      'border, not under it', (tester) async {
    final site = WebViewModel(initUrl: 'https://a.test', name: 'A');
    site.setTabs([
      SiteTab(id: site.activeTabId, url: 'https://a.test', title: 'one'),
      SiteTab(id: TabId('t2'), url: 'https://a.test/2', title: 'two'),
    ]);
    await tester.pumpWidget(localizedApp(Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 500,
          child: SidebarRail(
            sites: [site],
            current: null,
            width: 60,
            onOpen: (_) {},
            onOpenTab: (_, {required tabId}) {},
            onExpand: () {},
            onHide: () {},
          ),
        ),
      ),
    )));
    expect(find.byType(TabCountPill), findsOneWidget);
    final square = find
        .ancestor(
          of: find.byType(UnifiedFaviconImage),
          matching: find.byType(Material),
        )
        .first;
    expect(
      find.descendant(of: square, matching: find.byType(TabCountPill)),
      findsNothing,
      reason: 'a Material paints its border over its children',
    );
  });
}
