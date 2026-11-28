import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/localized.dart';
import 'helpers/real_app.dart';
import 'helpers/semantics_actions.dart';

/// Every control of the chrome has a name, a role and an action a screen
/// reader reaches: the real app's common screens hold no tappable node
/// without a label, a site in the drawer opens, is moved and shows its menu
/// through semantics alone, the site menu's top row is four controls, not
/// one, with its long presses as actions, and the find bar's match count is
/// read as it changes.
void main() {
  const phone = Size(400, 800);

  List<WebViewModel> sites() => [
        for (final name in ['Docs', 'Mail', 'News'])
          WebViewModel(initUrl: 'https://${name.toLowerCase()}.test', name: name),
      ];

  Future<void> start(WidgetTester tester,
      {Map<String, Object> prefs = const {}}) async {
    setViewSize(tester, size: phone);
    await pumpRealApp(tester, sites: sites(), prefs: prefs);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Docs');
  }

  Future<void> named(WidgetTester tester) =>
      expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

  Future<void> namedScrolled(WidgetTester tester) async {
    await named(tester);
    for (var i = 0; i < 8; i++) {
      final list = find.byType(Scrollable);
      if (list.evaluate().isEmpty) return;
      await tester.drag(list.last, const Offset(0, -500));
      await settleRealApp(tester);
      await named(tester);
    }
  }

  testWidgets('every tappable node is named: the app bar, the drawer and the '
      'site strip', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester,
        prefs: {'siteNavigation': 'strip', 'siteStripHidden': false});
    await named(tester);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    await named(tester);
    semantics.dispose();
  });

  testWidgets('every tappable node is named: App Settings and its screens',
      (tester) async {
    final semantics = tester.ensureSemantics();
    setViewSize(tester, size: phone);
    await pumpRealApp(tester, sites: sites(), prefs: {'developerMode': true});
    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    await namedScrolled(tester);
    for (final screen in [
      'Appearance',
      'Behaviour',
      'Network',
      'Privacy',
      'User Scripts',
      'Backup and archives',
      'Developer',
    ]) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, 3000));
      await settleRealApp(tester);
      await tester.scrollUntilVisible(find.text(screen), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text(screen));
      await settleRealApp(tester);
      await namedScrolled(tester);
      await tester.pageBack();
      await settleRealApp(tester);
    }
    semantics.dispose();
  });

  testWidgets("every tappable node is named: the site menu and a site's "
      'settings', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester);
    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
    await settleRealApp(tester);
    await named(tester);
    await tester.tap(find.text('Settings').last);
    await settleRealApp(tester);
    await namedScrolled(tester);
    semantics.dispose();
  });

  testWidgets('a screen reader opens, moves and asks the menu of a site in '
      'the drawer', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    SemanticsFinder tile(String name) => pressable(name);
    double left(String name) => tester
        .getTopLeft(find.descendant(
            of: find.byType(SiteGridTile), matching: find.text(name)))
        .dx;

    expect(tile('Docs').evaluate().single,
        containsSemantics(isButton: true, isSelected: true));
    expect(tile('Mail').evaluate().single, containsSemantics(isSelected: false));
    expect(customActionsOf(tile('Mail')), {'Menu', 'Move up', 'Move down'});

    performCustomAction(tile('Mail'), label: 'Move up');
    await settleRealApp(tester);
    expect(left('Mail'), lessThan(left('Docs')),
        reason: 'the move reorders without a drag');

    performCustomAction(tile('News'), label: 'Menu');
    await settleRealApp(tester);
    expect(find.text('Edit'), findsOneWidget);
    await tester.tapAt(const Offset(390, 790));
    await settleRealApp(tester);

    tester.semantics.tap(tile('News'));
    await settleRealApp(tester);
    expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('News')),
        findsOneWidget);
    semantics.dispose();
  });

  testWidgets("the site menu's top row is four controls, its long presses "
      'actions', (tester) async {
    final semantics = tester.ensureSemantics();
    final pressed = <String>[];
    await pumpLocalized(tester,
        home: Scaffold(
          body: Builder(
            builder: (context) => PopupMenuButton<int>(
              tooltip: 'Open',
              itemBuilder: (menuContext) => [
                siteMenuNavRow(menuContext,
                    nav: (
                      back: () => pressed.add('back'),
                      home: () => pressed.add('home'),
                      share: () => pressed.add('share'),
                      reload: () => pressed.add('reload'),
                      stop: () => pressed.add('stop'),
                      backInNewTab: () => pressed.add('back in new tab'),
                      duplicateTab: () => pressed.add('duplicate'),
                    ),
                    loading: false),
              ],
            ),
          ),
        ));
    Future<void> open() async {
      await tester.tap(find.byTooltip('Open'));
      await tester.pumpAndSettle();
    }

    SemanticsFinder button(String name) => pressable(name);

    await open();
    final ids = {
      for (final name in ['Go Back', 'Go to Home', 'Share', 'Refresh'])
        button(name).evaluate().single.id,
    };
    expect(ids, hasLength(4), reason: 'one node each, not one for the row');
    expect(customActionsOf(button('Go Back')), {'Back in a new tab'});
    expect(customActionsOf(button('Refresh')), {'Duplicate tab'});
    expect(customActionsOf(button('Share')), isEmpty);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    tester.semantics.tap(button('Share'));
    await tester.pumpAndSettle();
    await open();
    performCustomAction(button('Refresh'), label: 'Duplicate tab');
    await tester.pumpAndSettle();
    await open();
    performCustomAction(button('Go Back'), label: 'Back in a new tab');
    await tester.pumpAndSettle();
    expect(pressed, ['share', 'duplicate', 'back in new tab']);
    expect(find.byTooltip('Share'), findsNothing, reason: 'each closes the menu');
    semantics.dispose();
  });

  testWidgets("the find bar's match count is read as it changes",
      (tester) async {
    final semantics = tester.ensureSemantics();
    final matches = FindMatchesResult()
      ..activeMatchOrdinal = 2
      ..numberOfMatches = 5;
    await pumpLocalized(tester,
        home: Scaffold(
          body: FindToolbar(
            webViewController: null,
            matches: matches,
            onClose: () {},
          ),
        ));
    expect(tester.getSemantics(find.text('2/5')),
        containsSemantics(label: '2/5', isLiveRegion: true));
    semantics.dispose();
  });
}
