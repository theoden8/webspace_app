import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// The platform views a screen reader can reach: those with a node in the
/// semantics tree.
Set<int> reachablePages() => {
  for (final node in find.semantics
      .byPredicate((node) => node.platformViewId != null)
      .evaluate())
    node.platformViewId!,
};

/// The platform view of every page the app keeps, on screen or not.
Set<int> pagesKept() => {
  for (final surface in find
      .byWidgetPredicate((w) => w is PlatformViewSurface, skipOffstage: false)
      .evaluate())
    (surface.widget as PlatformViewSurface).controller.viewId,
};

/// The library's Add Site button, as a screen reader finds it.
final addSite = find.semantics.byPredicate((node) {
  final data = node.getSemanticsData();
  return data.label == 'Add Site' || data.tooltip == 'Add Site';
});

/// A screen reader reaches the page of the site on screen and nothing of the
/// sites, tabs or library it hides: the semantics tree is all it reads, and
/// the pages stay mounted off screen so they keep their state. Whether
/// VoiceOver and TalkBack go on into the page's own tree is a device's to
/// show; this holds what the app hands them.
void main() {
  late SemanticsHandle semantics;
  setUp(() => semantics = SemanticsBinding.instance.ensureSemantics());
  tearDown(() => semantics.dispose());

  Future<void> start(WidgetTester tester) async {
    await pumpRealApp(tester, sites: [
      WebViewModel(initUrl: 'https://one.test', name: 'One'),
      WebViewModel(initUrl: 'https://two.test', name: 'Two'),
    ]);
  }

  testWidgets('only the site on screen has its page in the semantics tree', (
    tester,
  ) async {
    await start(tester);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
    final one = pagesKept().single;
    expect(reachablePages(), {one});

    await openSiteFromDrawer(tester, name: 'Two');
    await attachWebViews(tester);
    final two = pagesKept().difference({one}).single;
    expect(pagesKept(), {one, two}, reason: 'One stays loaded behind Two');
    expect(reachablePages(), {two});
  });

  testWidgets('a tab kept warm behind the one on screen is not reached', (
    tester,
  ) async {
    await start(tester);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
    final first = pagesKept().single;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleRealApp(tester);
    await attachWebViews(tester);
    expect(appSite('One').tabs, hasLength(2));

    final second = pagesKept().difference({first}).single;
    expect(pagesKept(), {first, second}, reason: 'the first tab stays warm');
    expect(reachablePages(), {second});
  });

  testWidgets('the library and a site never share the semantics tree', (
    tester,
  ) async {
    await start(tester);
    await openWebspace(tester, name: 'All');
    expect(addSite, findsWidgets);
    expect(reachablePages(), isEmpty);

    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
    expect(addSite, findsNothing,
        reason: 'the library behind the site is not read');
    final one = pagesKept().single;
    expect(reachablePages(), {one});

    await openSiteFromDrawer(tester, name: 'Back to Webspaces');
    expect(pagesKept(), {one}, reason: 'One stays loaded behind the library');
    expect(reachablePages(), isEmpty,
        reason: 'the site behind the library is not read');
    expect(addSite, findsWidgets);
  });
}
