import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/open_sites.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_squares.dart';

import 'helpers/localized.dart';

void main() {
  testWidgets('TAB-034 a square centres its icon and name, however short the '
      'name', (tester) async {
    await tester.pumpWidget(localizedApp(Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          height: 400,
          child: SidebarSquares(
            sites: [WebViewModel(initUrl: 'https://a.test', name: 'A')],
            current: null,
            open: const OpenSites(),
            onSquare: (_) {},
            onToggleOpen: (_) {},
            actions: (
              open: (_, {required tabId}) {},
              close: (_, {required tabId}) {},
              add: (_) {},
            ),
            onMenu: (_, {required site, required position}) {},
          ),
        ),
      ),
    )));
    final icon = find.byType(UnifiedFaviconImage);
    final square = find.ancestor(of: icon, matching: find.byType(Material)).first;
    final middle = tester.getCenter(square).dx;
    expect(tester.getCenter(icon).dx, closeTo(middle, 0.5));
    expect(tester.getCenter(find.text('A')).dx, closeTo(middle, 0.5));
  });
}
