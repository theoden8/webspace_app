import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_rail.dart';

import 'helpers/localized.dart';

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
}
