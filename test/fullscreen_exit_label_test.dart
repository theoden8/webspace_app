import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/real_app.dart';

/// A11Y-015: the exit hint full screen shows is a two-second snack bar with
/// no action, which a screen reader can miss. The handle it describes is
/// then the one exit left, so it is a button named as the menu's exit is,
/// and its semantic tap leaves full screen as a TalkBack double tap would.
void main() {
  testWidgets('A11Y-015: full screen leaves a named exit a screen reader can use',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpRealApp(tester,
        sites: [WebViewModel(initUrl: 'https://example.com', name: 'Example')]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Example');
    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsNothing);

    final exit = find.semantics.byLabel('Exit Full Screen');
    expect(exit, findsOne);
    final node = exit.evaluate().single;
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    tester.semantics.tap(exit);
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(FullscreenExitHandle), findsNothing);
    semantics.dispose();
  });
}
