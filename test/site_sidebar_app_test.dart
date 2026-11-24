// The tab sidebar in the running app: its three states on a wide window and
// on a phone, each control the design gives it, and the page beside it.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_surface_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/navigation_choices.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';
import 'package:webspace/widgets/sidebar_rail.dart';
import 'package:webspace/widgets/sidebar_squares.dart';
import 'package:webspace/widgets/site_navigation_frame.dart';
import 'package:webspace/widgets/site_sidebar.dart';
import 'package:webspace/widgets/site_strip.dart';
import 'package:webspace/widgets/tab_chips.dart';
import 'package:webspace/widgets/tabs_sheet.dart';

import 'helpers/localized.dart';
import 'helpers/model_fixture.dart';
import 'helpers/real_app.dart';

WebViewModel withTabs(String name, {required List<String> titles}) {
  final url = 'https://${name.toLowerCase()}.test';
  final m = WebViewModel(initUrl: url, name: name);
  m.setTabs([
    SiteTab(id: m.activeTabId, url: url, title: titles.first),
    for (var i = 1; i < titles.length; i++)
      SiteTab(
        id: TabId('${name}t$i'),
        url: '$url/$i',
        title: titles[i],
        parentId: m.activeTabId,
      ),
  ]);
  return m;
}

const wide = Size(1200, 900);
const phone = Size(360, 740);

Future<void> start(
  WidgetTester tester, {
  Size size = wide,
  Map<String, Object> prefs = const {},
}) async {
  setViewSize(tester, size: size);
  await pumpRealApp(
    tester,
    sites: [
      withTabs('Docs', titles: ['Q3 plan', 'Budget 2027']),
      withTabs('Mail', titles: ['Inbox', 'Re: Q3 plan']),
    ],
    prefs: {'legacyDesign': false, 'siteNavigation': 'sidebar', ...prefs},
  );
  await openWebspace(tester, name: 'All');
  await openSiteFromDrawer(tester, name: 'Docs');
}

Finder docked(Type type) => find.descendant(
  of: find.byType(SiteNavigationFrame),
  matching: find.byType(type),
);

/// The frame alone, with reduced motion, its sidebar standing in boxes.
Widget frame(
  SidebarDock dock, {
  bool expandsOnHover = false,
  SidebarFloat float = SidebarFloat.none,
  VoidCallback? onDismissFloat,
  VoidCallback? onEdgeSwipe,
}) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(
      body: SiteNavigationFrame(
        surfaces: (
          strip: false,
          dock: dock,
          float: float,
          arrowTab: false,
          tabCountButton: false,
          stripButton: false,
        ),
        main: const SizedBox.expand(key: ValueKey('page')),
        panelWidth: 260,
        floatWidth: 260,
        railWidth: 60,
        panel: (width, {required floating}) =>
            SizedBox(key: const ValueKey('panel'), width: width),
        expandsOnHover: expandsOnHover,
        rail: const SizedBox(width: 60),
        handleFraction: 0.5,
        revealsOverlay: false,
        onArrowTap: () {},
        onSettle: (SidebarState _) {},
        onReveal: (bool _) {},
        onDismissFloat: onDismissFloat ?? () {},
        onEdgeSwipe: onEdgeSwipe,
        onHandleMoved: (double _) {},
        onResize: (double _) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('TAB-032 wide: open, the collapse button gives the rail, its cross '
      'hides it, and only the arrow tab brings it back', (tester) async {
    await start(tester);
    expect(find.byType(SiteSidebar), findsWidgets);
    expect(
      find.byType(SiteStrip),
      findsNothing,
      reason: 'the strip never shows with the sidebar',
    );
    expect(find.byType(SidebarArrowTab), findsNothing);

    await tester.tap(find.byTooltip('Collapse to the rail').first);
    await settleRealApp(tester);
    expect(find.byType(SidebarRail), findsOneWidget);
    expect(AppPref.sidebarState.value, 'collapsed');
    expect(
      find.byType(SidebarArrowTab),
      findsNothing,
      reason: 'the rail is its own handle',
    );

    await tester.tap(find.byTooltip('Hide the sidebar'));
    await settleRealApp(tester);
    expect(AppPref.sidebarState.value, 'hidden');
    expect(find.byType(SidebarArrowTab), findsOneWidget);

    expect(
      find.byTooltip('Open the tab sidebar'),
      findsNothing,
      reason: 'the arrow tab brings it back; the app bar carries no second '
          'way to the same place',
    );
    await tester.tap(find.byType(SidebarArrowTab));
    await settleRealApp(tester);
    expect(AppPref.sidebarState.value, 'collapsed',
        reason: 'back as it was left');
  });

  testWidgets('TAB-032 wide: the arrow tab brings it back as it was left; a short '
      'pull settles at the rail', (tester) async {
    await start(tester, prefs: {'sidebarState': 'collapsed'});
    await tester.tap(find.byTooltip('Hide the sidebar'));
    await settleRealApp(tester);
    await tester.tap(find.byType(SidebarArrowTab));
    await settleRealApp(tester);
    expect(AppPref.sidebarState.value, 'collapsed');

    await tester.tap(find.byTooltip('Hide the sidebar'));
    await settleRealApp(tester);
    await tester.drag(find.byType(SidebarArrowTab), const Offset(70, 0));
    await settleRealApp(tester);
    expect(AppPref.sidebarState.value, 'collapsed');
  });

  testWidgets('squares by default: the site on screen opens its tabs (TAB-034)', (
    tester,
  ) async {
    await start(tester);
    expect(find.byType(SidebarSquares), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidebarSquares),
        matching: find.widgetWithText(TabChip, 'Budget 2027'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the tree, when chosen, is the Tabs sheet as the sidebar (TAB-034)', (
    tester,
  ) async {
    await start(tester, prefs: {'sidebarStyle': 'tree'});
    final tree = tester.widget<TabsSheet>(find.byType(TabsSheet).first);
    expect(tree.host, TabsSheetHost.sidebar);
  });

  testWidgets('TAB-033 phone: the rail stays, expand opens the drawer, a pick drops '
      'back to the rail', (tester) async {
    await start(tester, size: phone);
    expect(find.byType(SidebarSquares), findsNothing,
        reason: 'a phone starts at the rail');
    expect(tester.getSize(find.byType(SidebarRail)).width, 52);

    await tester.tap(find.byTooltip('Expand the sidebar'));
    await settleRealApp(tester);
    expect(find.byType(SidebarSquares), findsOneWidget);
    await tester.tap(find.widgetWithText(TabChip, 'Budget 2027').last);
    await settleRealApp(tester);
    expect(find.byType(SidebarSquares), findsNothing);
    expect(find.byType(SidebarRail), findsOneWidget);
    expect(appSite('Docs').activeTabId, TabId('Docst1'));
  });

  testWidgets('TAB-033: a narrow window shows the rail and keeps the state; '
      'widening opens it again', (tester) async {
    await start(tester);
    setViewSize(tester, size: phone);
    await settleRealApp(tester);
    expect(find.byType(SidebarRail), findsOneWidget);
    expect(docked(SidebarSquares), findsNothing);
    expect(AppPref.sidebarState.value, 'open');
    setViewSize(tester, size: wide);
    await settleRealApp(tester);
    expect(docked(SidebarSquares), findsOneWidget);
  });

  testWidgets('TAB-031, TAB-034: the squares follow a switch; the site on '
      'screen shows its tabs', (tester) async {
    await start(tester);
    Finder square(String name) => find.descendant(
        of: find.byType(SidebarSquares), matching: find.text(name));
    await tester.tap(square('Docs'));
    await settleRealApp(tester);
    expect(find.widgetWithText(TabChip, 'Budget 2027'), findsNothing,
        reason: 'a second tap closes them');
    await tester.tap(square('Mail'));
    await settleRealApp(tester);
    await tester.tap(square('Docs'));
    await settleRealApp(tester);
    expect(find.widgetWithText(TabChip, 'Budget 2027'), findsOneWidget);
  });

  testWidgets('the edge resizes it on release, within 200 to 420 (TAB-032)', (
    tester,
  ) async {
    await start(tester);
    final sidebar = docked(SiteSidebar).first;
    final edge = tester.getTopRight(sidebar) + const Offset(-3, 300);
    await tester.dragFrom(edge, const Offset(40, 0));
    await settleRealApp(tester);
    expect(AppPref.sidebarWidth.value, 300);
    await tester.dragFrom(edge + const Offset(40, 0), const Offset(400, 0));
    await settleRealApp(tester);
    expect(AppPref.sidebarWidth.value, 420);
  });

  testWidgets('TAB-037 expand on hover: the rail opens over the page while the '
      'pointer rests on it', (tester) async {
    await tester.pumpWidget(frame(SidebarDock.rail, expandsOnHover: true));
    expect(find.byKey(const ValueKey('panel')), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(600, 300));
    await mouse.moveTo(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page'))).dx,
      60,
      reason: 'over the page, which keeps its width',
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('panel'))).dx,
      60,
      reason: 'beside the rail, whose own controls (its cross among them) '
          'stay where the pointer can reach them',
    );
    await mouse.moveTo(const Offset(30, 580));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel')), findsOneWidget,
        reason: 'still on the rail');
    await mouse.moveTo(const Offset(200, 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('panel')),
      findsOneWidget,
      reason: 'still on the open sidebar',
    );
    await mouse.moveTo(const Offset(600, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel')), findsNothing);
  });

  testWidgets('TAB-033 a swipe right from the screen edge over the docked '
      'rail is the page\'s back swipe; elsewhere on the rail it is not', (
    tester,
  ) async {
    var swiped = 0;
    await tester.pumpWidget(frame(
      SidebarDock.rail,
      onEdgeSwipe: () => swiped++,
    ));
    await tester.dragFrom(const Offset(4, 300), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(swiped, 1);

    await tester.dragFrom(const Offset(40, 300), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(swiped, 1, reason: 'not from the edge');

    await tester.dragFrom(const Offset(4, 300), const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(swiped, 1, reason: 'too short');

    await tester.tapAt(const Offset(4, 300));
    await tester.pumpAndSettle();
    expect(swiped, 1, reason: 'a tap is the rail\'s');
  });

  testWidgets('TAB-033 a swipe left puts the drawer away; a short one does '
      'not', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(frame(
      SidebarDock.rail,
      float: SidebarFloat.drawer,
      onDismissFloat: () => dismissed++,
    ));
    final drawer = find.byKey(const ValueKey('panel'));
    expect(drawer, findsOneWidget);

    await tester.drag(drawer, const Offset(-30, 0));
    await tester.pumpAndSettle();
    expect(dismissed, 0, reason: 'a short drag springs back');
    expect(tester.getTopLeft(drawer).dx, 0);

    await tester.drag(drawer, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(dismissed, 1);

    await tester.fling(drawer, const Offset(-60, 0), 1200);
    await tester.pumpAndSettle();
    expect(dismissed, 2, reason: 'a quick flick is enough');
  });

  testWidgets('with reduced motion the page takes its width at once (TAB-035)', (
    tester,
  ) async {
    await tester.pumpWidget(frame(SidebarDock.full));
    expect(tester.getTopLeft(find.byKey(const ValueKey('page'))).dx, 260);
    await tester.pumpWidget(frame(SidebarDock.rail));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey('page'))).dx, 60);
  });
}
