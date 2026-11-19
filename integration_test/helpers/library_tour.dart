import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

/// How a run of [walkLibraryTour] waits and what it does at each stop: the
/// screenshot test waits on the real clock and captures the window, the
/// widget test pumps fake time and records the names.
typedef TourHost = ({
  Future<void> Function() settle,
  Future<void> Function() pageLoad,
  Future<void> Function(String baseName) shoot,
});

Finder _folder(String name) => find.byWidgetPredicate(
  (widget) => widget is WebspaceGroupTile && widget.webspace.name == name,
);

Finder _site(String name) => find.byWidgetPredicate(
  (widget) => widget is SiteGridTile && widget.site.name == name,
);

/// The store screenshots (SCREENSHOT-003) on the demo data, in the library
/// design a fresh install starts in (WEBSPACE-019): the folders, the Work
/// folder open, a site's settings, and a webspace being made. Every stop
/// expects what it shows, so a design the tour no longer matches fails here
/// instead of capturing another screen.
Future<void> walkLibraryTour(
  WidgetTester tester, {
  required TourHost host,
}) async {
  expect(find.byType(WebspaceLibrary), findsOneWidget,
      reason: 'the demo is a fresh install, which starts in the library');
  expect(find.byType(Drawer), findsNothing);
  expect(_folder('Work'), findsOneWidget);
  await host.shoot('02-webspace-library');

  await tester.tap(_folder('Work'));
  await host.settle();
  expect(_site('GitHub'), findsOneWidget, reason: 'the Work folder is open');
  await host.shoot('03-work-webspace');

  await tester.binding.handlePopRoute();
  await host.settle();
  await tester.tap(_folder('Privacy'));
  await host.settle();
  await tester.tap(_site('SearXNG'));
  await host.settle();
  await host.pageLoad();
  await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
  await host.settle();
  await tester.tap(find.text('Settings').last);
  await host.settle();
  expect(find.byType(WebspaceLibrary), findsNothing);
  await host.shoot('01-site-settings');

  await tester.binding.handlePopRoute();
  await host.settle();
  await tester.tap(find.byTooltip('Back to Webspaces'));
  await host.settle();
  tester.state<WebspaceLibraryState>(find.byType(WebspaceLibrary)).closeFolder();
  await host.settle();
  await tester.tap(find.byTooltip('Add'));
  await host.settle();
  await tester.tap(find.text('Create Webspace').last);
  await host.settle();
  await tester.enterText(find.byType(TextField).first, 'Entertainment');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await host.settle();
  for (final name in ['Reddit', 'Wikipedia']) {
    await tester.dragUntilVisible(
      find.text(name),
      find.byType(ListView).last,
      const Offset(0, -120),
    );
    await host.settle();
    final box = find.ancestor(
      of: find.text(name),
      matching: find.byType(CheckboxListTile),
    );
    expect(box, findsOneWidget, reason: '$name is offered for the webspace');
    await tester.tap(box);
    await host.settle();
  }
  await host.shoot('04-workspace-sites-selected');
}
