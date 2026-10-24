// Sites and tabs driven by a TV remote's D-pad and OK key alone (NAV-016),
// with Android's key bindings and the app's remote chrome around them.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/tab_strip_edge.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/remote_controls.dart';
import 'package:webspace/widgets/site_tab_strip.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'helpers/model_fixture.dart';

Future<void> _pumpTv(WidgetTester tester, {required Widget body}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => RemoteControls(child: child!),
    home: Scaffold(body: body),
  ));
  await tester.pumpAndSettle();
}

Future<void> _press(
  WidgetTester tester, {
  required LogicalKeyboardKey key,
}) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The texts under the control that has focus.
List<String> _focusedTexts() {
  final context = FocusManager.instance.primaryFocus?.context;
  final texts = <String>[];
  void visit(Element e) {
    if (e.widget case Text(:final data?)) texts.add(data);
    e.visitChildren(visit);
  }

  if (context case final Element element) visit(element);
  return texts;
}

WebViewModel _chain(String name, {required List<String> urls}) {
  final site = WebViewModel(initUrl: urls.first, name: name);
  var parent = site.activeTabId;
  for (final url in urls.skip(1)) {
    final tab = SiteTab(
      id: TabId('tab${site.tabs.length}'),
      url: url,
      parentId: parent,
    );
    site.setTabs([...site.tabs, tab]);
    parent = tab.id;
  }
  return site;
}

void main() {
  testWidgets(
      'a remote switches sites from the tab strip and opens the tabs of the '
      'one on screen (NAV-016)', (tester) async {
    final sites = [
      for (final name in ['Alpha', 'Beta', 'Gamma'])
        WebViewModel(initUrl: 'https://$name.test', name: name),
    ];
    final opened = <String>[];
    var tabsShown = 0;
    await _pumpTv(
      tester,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SiteTabStrip(
          edge: TabStripEdge.bottom,
          models: sites,
          order: const [0, 1, 2],
          current: 0,
          revealed: false,
          onHide: () {},
          onOpen: (site) => opened.add(site.name),
          onShowTabs: () => tabsShown++,
          onReorder: (from, {required to}) {},
          menu: const SizedBox.shrink(),
        ),
      ),
    );

    await _press(tester, key: LogicalKeyboardKey.arrowRight);
    expect(_focusedTexts(), contains('Alpha'));
    await _press(tester, key: LogicalKeyboardKey.select);
    expect(tabsShown, 1, reason: 'the chip on screen opens its tabs');

    await _press(tester, key: LogicalKeyboardKey.arrowRight);
    expect(_focusedTexts(), contains('Beta'));
    await _press(tester, key: LogicalKeyboardKey.enter);
    expect(opened, ['Beta']);

    expect(find.byKey(RemoteControls.ringKey), findsNothing,
        reason: 'a chip outlines itself, inside its margin');
  });

  testWidgets(
      'a remote reaches web search and every tab of the Tabs sheet, and opens '
      'a tab (NAV-016)', (tester) async {
    final site = _chain('Alpha', urls: [
      'https://a.test/1',
      'https://a.test/2',
      'https://a.test/3',
    ]);
    final events = <String>[];
    await _pumpTv(
      tester,
      body: TabsSheet(
        sites: [TabsSheetSite(model: site, isCurrent: true, isLoaded: true)],
        currentIndex: 0,
        onOpenTab: (s, {required tabId}) => events.add('open $tabId'),
        onNewTab: (s) => events.add('new'),
        onWebSearch: () => events.add('search'),
        onCloseTab: (s, {required tabId}) => events.add('close $tabId'),
        onCloseSubtree: (s, {required tabId}) => events.add('subtree $tabId'),
      ),
    );

    await _press(tester, key: LogicalKeyboardKey.arrowDown);
    expect(_focusedTexts(), contains('Web search'));

    final reached = <String>{};
    for (final key in [
      for (var i = 0; i < 6; i++) LogicalKeyboardKey.arrowDown,
      for (var i = 0; i < 2; i++) LogicalKeyboardKey.arrowUp,
    ]) {
      await _press(tester, key: key);
      reached.addAll(_focusedTexts());
    }
    expect(reached,
        containsAll(['https://a.test/1', 'https://a.test/2', 'https://a.test/3']));
    expect(_focusedTexts(), contains('https://a.test/1'));

    await _press(tester, key: LogicalKeyboardKey.select);
    expect(events, ['open ${site.tabs.first.id}']);
  });
}
