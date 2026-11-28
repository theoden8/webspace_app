import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/localized.dart';
import 'helpers/model_fixture.dart';
import 'helpers/real_app.dart';

/// The chrome stays dark in dark mode, whichever way the app got there: the
/// system's brightness under the default theme, or the in-app toggle. Every
/// screen, dialog, sheet and menu these tests reach paints its background
/// surfaces (a Scaffold, a Dialog, a sheet, the drawer, a popup menu, each a
/// [Material]) darker than [_darkest].
///
/// What a webview shows before its page paints is a device check; the
/// webview's own settings are in test/page_backdrop_test.dart.
void main() {
  WebViewModel withTabs(String name, {required List<String> titles}) {
    final url = 'https://${name.toLowerCase()}.test';
    final m = WebViewModel(initUrl: url, name: name);
    m.setTabs([
      SiteTab(id: m.activeTabId, url: url, title: titles.first),
      for (var i = 1; i < titles.length; i++)
        SiteTab(id: TabId('${name}t$i'), url: '$url/$i', title: titles[i],
            parentId: m.activeTabId),
    ]);
    return m;
  }

  List<WebViewModel> sites() => [
        withTabs('Docs', titles: ['Q3 plan', 'Budget 2027']),
        withTabs('Mail', titles: ['Inbox']),
        WebViewModel(initUrl: 'https://news.test', name: 'News'),
      ];

  const phone = Size(400, 800);

  testWidgets('dark interface: by the system, under the system theme',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    setViewSize(tester, size: phone);
    await pumpRealApp(tester, sites: sites(), prefs: {'developerMode': true});
    await _everyChromeSurfaceIsDark(tester);
  });

  testWidgets('dark interface: by the in-app toggle, the system light',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    setViewSize(tester, size: phone);
    await pumpRealApp(tester, sites: sites(), prefs: {'developerMode': true});
    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    await tester.tap(find.text('Appearance'));
    await settleRealApp(tester);
    await tester.tap(find.text('Dark'));
    await settleRealApp(tester);
    await tester.pageBack();
    await settleRealApp(tester);
    await tester.pageBack();
    await settleRealApp(tester);
    await _everyChromeSurfaceIsDark(tester);
  });

  testWidgets('dark interface: the check sees a light surface',
      (tester) async {
    await pumpLocalized(tester,
        size: phone,
        theme: ThemeData(brightness: Brightness.dark),
        home: const Scaffold(backgroundColor: Colors.white));
    expect(_lightSurfaces(where: 'planted'), isNotEmpty);
  });
}

/// Above this a surface is not dark: mid grey's luminance.
const _darkest = 0.18;

/// The colour [material] paints, or null where it paints none of its own.
Color? _painted(Element element) {
  final material = element.widget as Material;
  if (material.type == MaterialType.transparency) return null;
  final theme = Theme.of(element);
  final color = material.color ??
      (material.type == MaterialType.card
          ? theme.cardColor
          : theme.canvasColor);
  return ElevationOverlay.applySurfaceTint(
      color, material.surfaceTintColor, material.elevation);
}

/// The background surfaces on screen with the colour each paints: each
/// [Material] at least 120 by 120 that paints a mostly opaque colour, so a
/// page, a dialog, a sheet, the drawer or a menu, but no button or chip.
List<(Element, Color)> _backgrounds() => [
      for (final element in find.byType(Material).evaluate())
        if (_painted(element) case final color?
            when color.a >= 0.5 &&
                element.size != null &&
                element.size!.width >= 120 &&
                element.size!.height >= 120)
          (element, color),
    ];

/// Each background surface on screen lighter than [_darkest], named for the
/// failure.
List<String> _lightSurfaces({required String where}) => [
      for (final (element, color) in _backgrounds())
        if (color.computeLuminance() > _darkest)
          '$where: ${element.debugGetCreatorChain(8)} paints $color',
    ];

void _surfacesAreDark({required String where}) {
  expect(_backgrounds(), isNotEmpty, reason: '$where shows no surface');
  expect(_lightSurfaces(where: where), isEmpty);
}

/// The innermost list that scrolls down, rather than a text field's.
final _pageScroll = find.byWidgetPredicate((widget) =>
    widget is Scrollable && widget.axisDirection == AxisDirection.down);

/// [where], then scrolled down the last scrollable a screen at a time.
Future<void> _scrolledSurfacesAreDark(WidgetTester tester,
    {required String where}) async {
  _surfacesAreDark(where: where);
  for (var i = 0; i < 6; i++) {
    if (_pageScroll.evaluate().isEmpty) return;
    await tester.drag(_pageScroll.last, const Offset(0, -600));
    await settleRealApp(tester);
    _surfacesAreDark(where: '$where, scrolled');
  }
}

/// Walks the chrome from the start screen: App Settings and each of its
/// screens, the drawer, a site, its tabs sheet, its menu, its settings, their
/// confirm dialog and each of their screens, and Developer Tools.
Future<void> _everyChromeSurfaceIsDark(WidgetTester tester) async {
  _surfacesAreDark(where: 'the start screen');

  await tester.tap(find.byTooltip('App Settings'));
  await settleRealApp(tester);
  await _scrolledSurfacesAreDark(tester, where: 'App Settings');
  for (final screen in [
    'Appearance',
    'Behaviour',
    'Network',
    'Privacy',
    'User Scripts',
    'Backup and archives',
    'Developer',
  ]) {
    await tester.drag(_pageScroll.last, const Offset(0, 3000));
    await settleRealApp(tester);
    await tester.scrollUntilVisible(find.text(screen), 200,
        scrollable: _pageScroll.last);
    await tester.tap(find.text(screen));
    await settleRealApp(tester);
    await _scrolledSurfacesAreDark(tester, where: screen);
    await tester.pageBack();
    await settleRealApp(tester);
  }
  await tester.pageBack();
  await settleRealApp(tester);

  await openWebspace(tester, name: 'All');
  await openSiteFromDrawer(tester, name: 'Docs');
  _surfacesAreDark(where: 'a site on screen');

  await tester.tap(find.byTooltip('Open navigation menu'));
  await settleRealApp(tester);
  expect(find.byType(Drawer), findsOneWidget);
  _surfacesAreDark(where: 'the drawer');
  await tester.tap(find.text('Mail').last);
  await settleRealApp(tester);

  await openTabsSheet(tester);
  expect(find.byType(BottomSheet), findsOneWidget);
  _surfacesAreDark(where: 'the tabs sheet');
  await tester.tap(find.text('All sites'));
  await settleRealApp(tester);
  _surfacesAreDark(where: 'the tabs sheet, all sites');
  await tester.tapAt(const Offset(200, 20));
  await settleRealApp(tester);

  await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
  await settleRealApp(tester);
  _surfacesAreDark(where: 'the site menu');
  await tester.tap(find.text('Settings').last);
  await settleRealApp(tester);
  await _scrolledSurfacesAreDark(tester, where: "a site's settings");

  final clear = find.byIcon(Icons.cookie);
  await tester.scrollUntilVisible(clear, -200,
      scrollable: _pageScroll.last);
  await tester.tap(clear);
  await settleRealApp(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
  _surfacesAreDark(where: 'a confirm dialog');
  await tester.tap(find.text('Cancel'));
  await settleRealApp(tester);

  for (final screen in ['Permissions', 'Behaviour', 'Network', 'Privacy']) {
    await tester.drag(_pageScroll.last, const Offset(0, 3000));
    await settleRealApp(tester);
    await tester.scrollUntilVisible(find.text(screen), 200,
        scrollable: _pageScroll.last);
    await tester.tap(find.text(screen));
    await settleRealApp(tester);
    await _scrolledSurfacesAreDark(tester, where: "a site's $screen");
    await tester.pageBack();
    await settleRealApp(tester);
  }
  await tester.pageBack();
  await settleRealApp(tester);

  await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
  await settleRealApp(tester);
  await tester.tap(find.text('Developer Tools'));
  await settleRealApp(tester);
  _surfacesAreDark(where: 'Developer Tools');
}
