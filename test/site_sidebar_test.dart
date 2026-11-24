import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
