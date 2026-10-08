import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps frames in 100ms slices for [total]. pumpAndSettle deadlocks once a
/// webview is live, so a bounded run of slices is how these tests advance
/// the tree.
Future<void> pumpFor(WidgetTester tester, Duration total) async {
  final deadline = DateTime.now().add(total);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Polls on the real clock, inside `runAsync`, where sockets, platform
/// channels and the webview make progress while the test waits. Pumps no
/// frames.
class RealWait {
  const RealWait({
    this.log,
    this.timeout = const Duration(seconds: 30),
    this.interval = const Duration(milliseconds: 250),
  });

  final void Function(String message)? log;
  final Duration timeout;
  final Duration interval;

  /// Whether [done] held before [timeout], this wait's default when null.
  /// With a [label], logs `<label> -> ok|timeout`.
  Future<bool> call(
    WidgetTester tester,
    bool Function() done, {
    String? label,
    Duration? timeout,
  }) async {
    var ok = false;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout ?? this.timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (done()) {
          ok = true;
          return;
        }
        await Future<void>.delayed(interval);
      }
      ok = done();
    });
    if (label != null) log?.call('$label -> ${ok ? "ok" : "timeout"}');
    return ok;
  }
}

/// Opens the site drawer through the app bar's menu button, or through the
/// first Scaffold that has a drawer when the bar shows none, retrying while a
/// rebuild swallows the gesture.
Future<void> openSiteDrawer(WidgetTester tester) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    if (find.byType(Drawer).evaluate().isNotEmpty) return;
    final menuIcon = find.byIcon(Icons.menu);
    if (menuIcon.evaluate().isNotEmpty) {
      await tester.tap(menuIcon.first);
    } else {
      for (final element in find.byType(Scaffold).evaluate()) {
        final state = tester
            .state<ScaffoldState>(find.byWidget(element.widget as Scaffold));
        if (state.hasDrawer) {
          state.openDrawer();
          break;
        }
      }
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  expect(find.byType(Drawer), findsOneWidget,
      reason: 'site drawer should open for switching sites');
}

/// Taps [siteName]'s tile. The active site's name can also be the app bar
/// title, so the search is scoped to the open drawer when there is one.
/// [diagnose] runs before the failure when no tile is found.
Future<void> tapSite(
  WidgetTester tester,
  String siteName, {
  void Function(String context)? diagnose,
}) async {
  final drawer = find.byType(Drawer);
  final tile = drawer.evaluate().isNotEmpty
      ? find.descendant(of: drawer, matching: find.text(siteName))
      : find.text(siteName);
  if (tile.evaluate().isEmpty) diagnose?.call('site tile "$siteName" missing');
  expect(tile, findsWidgets, reason: '$siteName should be in the site list');
  await tester.tap(tile.first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
