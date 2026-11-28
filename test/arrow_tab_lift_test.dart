// TAB-038: the sidebar's arrow tab and the site strip's button are one
// control. A hold lifts the tab; let go on the page it is the strip's button
// there, let go on the left edge it stays the tab at that height. The
// strip's button, dragged to the left edge, docks as the tab. The first tab
// says so, once.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/navigation_surface_engine.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/settings/navigation_choices.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';
import 'package:webspace/widgets/site_navigation_frame.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

import 'helpers/localized.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'sidebarArrowDragHintShown': true});
    ArrowDragHint.forget();
  });

  late List<Alignment> liftedOff;
  late List<double> handle;

  Widget frame() {
    liftedOff = [];
    handle = [];
    return localizedApp(
      MediaQuery(
        data: const MediaQueryData(size: Size(800, 600), disableAnimations: true),
        child: Scaffold(
          body: SiteNavigationFrame(
            surfaces: (
              strip: false,
              dock: SidebarDock.none,
              float: SidebarFloat.none,
              arrowTab: true,
              tabCountButton: false,
              stripButton: false,
            ),
            main: const SizedBox.expand(key: ValueKey('page')),
            panelWidth: 260,
            floatWidth: 260,
            railWidth: 60,
            panel: (width, {required floating}) => SizedBox(width: width),
            expandsOnHover: false,
            rail: const SizedBox(width: 60),
            handleFraction: 0.5,
            revealsOverlay: false,
            onArrowTap: () {},
            onSettle: (SidebarState _) {},
            onReveal: (bool _) {},
            onDismissFloat: () {},
            onHandleMoved: handle.add,
            onLiftedOff: liftedOff.add,
            onResize: (double _) {},
          ),
        ),
      ),
    );
  }

  Future<TestGesture> lift(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SidebarArrowTab)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    return gesture;
  }

  testWidgets('TAB-038 held and let go on the page, the arrow tab becomes the '
      'strip\'s button there', (tester) async {
    await tester.pumpWidget(frame());
    expect(find.byType(DockZone), findsNothing);
    final gesture = await lift(tester);
    expect(find.byType(DockZone), findsOneWidget,
        reason: 'the edge shows where it would dock');
    await gesture.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(find.byType(TabBarCornerButton), findsOneWidget,
        reason: 'off the edge it is drawn as the button');
    await gesture.up();
    await tester.pump();
    expect(liftedOff, hasLength(1));
    expect(
      tabBarCornerNearest(liftedOff.single.x, y: liftedOff.single.y),
      TabBarCorner.bottomRight,
    );
    expect(handle, isEmpty);
    expect(find.byType(DockZone), findsNothing);
  });

  testWidgets('TAB-038 let go on the left edge it stays the arrow tab, at that '
      'height', (tester) async {
    await tester.pumpWidget(frame());
    final gesture = await lift(tester);
    await gesture.moveTo(const Offset(10, 450));
    await tester.pump();
    expect(find.byType(TabBarCornerButton), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(liftedOff, isEmpty);
    expect(handle.single, closeTo((450 - 30) / (600 - 60), 0.01));
  });

  testWidgets('TAB-038 the strip\'s button dragged to the left edge docks as '
      'the arrow tab; elsewhere it picks a corner', (tester) async {
    final docked = <double>[];
    final corners = <TabBarCorner>[];
    await tester.pumpWidget(localizedApp(
      Scaffold(
        body: SizedBox(
          width: 400,
          height: 800,
          child: TabBarCornerOverlay(
            corner: TabBarCorner.bottomRight,
            onTap: () {},
            onCornerChosen: corners.add,
            onDock: docked.add,
          ),
        ),
      ),
    ));
    final button = find.byType(TabBarCornerButton);
    var gesture = await tester.startGesture(tester.getCenter(button));
    await gesture.moveBy(const Offset(-40, -40));
    await tester.pump();
    await gesture.moveTo(const Offset(8, 200));
    await tester.pump();
    expect(find.byType(DockZone), findsOneWidget);
    expect(find.byType(ArrowTabFace), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    final height = tester.getSize(find.byType(TabBarCornerOverlay)).height;
    expect(docked.single, closeTo(200 / height, 0.01));
    expect(corners, isEmpty);

    gesture = await tester.startGesture(tester.getCenter(button));
    await gesture.moveBy(const Offset(-40, -40));
    await tester.pump();
    await gesture.moveTo(const Offset(300, 100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(corners, [TabBarCorner.topRight]);
    expect(docked, hasLength(1));
  });

  testWidgets('a screen reader moves the arrow tab along the edge through '
      'its scroll actions, as a drag up or down does', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(frame());
    final tab = find.semantics.byPredicate(
        (node) => node.tooltip == 'Show the tab sidebar',
        describeMatch: (_) => 'the arrow tab');
    tester.semantics.performAction(tab, SemanticsAction.scrollUp);
    await tester.pumpAndSettle();
    expect(handle, [lessThan(0.5)]);
    tester.semantics.performAction(tab, SemanticsAction.scrollDown);
    await tester.pumpAndSettle();
    expect(handle.last, greaterThan(0.5),
        reason: 'the frame here keeps the fraction it was built with');
    semantics.dispose();
  });

  testWidgets('TAB-038 the first arrow tab says, once, that it can be dragged '
      'onto the page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final hint = 'Hold the arrow and drag it onto the page to use the site '
        'strip instead';
    await tester.pumpWidget(frame());
    await tester.pump();
    await tester.pump();
    expect(find.text(hint), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(ArrowDragHint.shownKey), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle(const Duration(seconds: 7));
    ArrowDragHint.forget();
    await tester.pumpWidget(frame());
    await tester.pump();
    await tester.pump();
    expect(find.text(hint), findsNothing, reason: 'remembered');
  });
}
