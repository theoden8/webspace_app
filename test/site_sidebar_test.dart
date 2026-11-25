import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/navigation_choices.dart';
import 'package:webspace/widgets/site_sidebar.dart';

import 'helpers/localized.dart';

void main() {
  testWidgets('TAB-034 a short title sits level with the collapse button',
      (tester) async {
    await tester.pumpWidget(localizedApp(Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 400,
          child: SiteSidebar(
            width: 260,
            title: const Text('Dev'),
            body: const SizedBox.shrink(),
            onCollapse: () {},
            collapseTooltip: 'Collapse to the rail',
          ),
        ),
      ),
    )));
    final title = tester.getCenter(find.text('Dev')).dy;
    final button = tester.getCenter(find.byTooltip('Collapse to the rail')).dy;
    expect(title, closeTo(button, 1));
  });

  testWidgets('TAB-034 the sidebar\'s own toggle switches squares and the tab '
      'tree', (tester) async {
    final picked = <SidebarStyle>[];
    Future<void> pump(SidebarStyle style) => tester.pumpWidget(localizedApp(
          Scaffold(
            body: SizedBox(
              height: 400,
              child: SiteSidebar(
                width: 260,
                title: const Text('Dev'),
                body: const SizedBox.shrink(),
                view: (style: style, onChanged: picked.add),
                onCollapse: () {},
                collapseTooltip: 'Collapse to the rail',
              ),
            ),
          ),
        ));
    await pump(SidebarStyle.squares);
    await tester.tap(find.byTooltip('Tab tree'));
    await pump(SidebarStyle.tree);
    await tester.tap(find.byTooltip('Squares'));
    expect(picked, [SidebarStyle.tree, SidebarStyle.squares]);
  });
}
