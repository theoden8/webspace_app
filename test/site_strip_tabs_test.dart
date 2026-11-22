// The site strip with tabs: a site's chip opens out to show its tabs, in the
// order they were opened; the site on screen is open, any other by its arrow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/open_sites.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/site_strip_edge.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_strip.dart';
import 'package:webspace/widgets/tab_chips.dart';

import 'helpers/localized.dart';
import 'helpers/model_fixture.dart';

WebViewModel titled(String name, {required List<String> titles}) {
  final m = WebViewModel(initUrl: 'https://${name.toLowerCase()}.test', name: name);
  var parent = m.activeTabId;
  m.setTabs([
    SiteTab(id: m.activeTabId, url: m.initUrl, title: titles.first),
    for (var i = 1; i < titles.length; i++)
      SiteTab(
          id: TabId('${name}t$i'),
          url: '${m.initUrl}/$i',
          title: titles[i],
          parentId: i == 1 ? parent : TabId('${name}t${i - 1}')),
  ]);
  return m;
}

class _Strip {
  final toggled = <String>[];
  final openedTabs = <String>[];
  final closed = <String>[];
  final added = <String>[];
  var shown = 0;
}

Future<_Strip> pumpStrip(WidgetTester tester,
    {required List<WebViewModel> sites,
    OpenSites open = const OpenSites(),
    int current = 0}) async {
  final log = _Strip();
  setViewSize(tester, size: const Size(1200, 400));
  await pumpLocalized(tester,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SiteStrip(
            edge: SiteStripEdge.top,
            models: sites,
            order: [for (var i = 0; i < sites.length; i++) i],
            current: current,
            revealed: false,
            onHide: () {},
            onOpen: (_) {},
            onShowTabs: () => log.shown++,
            onReorder: null,
            menu: const SizedBox.shrink(),
            open: open,
            onToggleOpen: (id) => log.toggled.add(id),
            tabs: (
              open: (site, {required tabId}) =>
                  log.openedTabs.add('${site.name}/$tabId'),
              close: (site, {required tabId}) =>
                  log.closed.add('${site.name}/$tabId'),
              add: (site) => log.added.add(site.name),
            ),
          ),
        ),
      ));
  await tester.pump();
  return log;
}

void main() {
  late WebViewModel docs;
  late WebViewModel mail;

  setUp(() {
    docs = titled('Docs', titles: ['Q3 plan', 'Budget 2027', 'Hiring sheet']);
    mail = titled('Mail', titles: ['Inbox', 'Re: Q3 plan']);
  });

  testWidgets('the site on screen shows its tabs; another shows its count',
      (tester) async {
    await pumpStrip(tester, sites: [docs, mail]);
    for (final title in ['Q3 plan', 'Budget 2027', 'Hiring sheet']) {
      expect(find.widgetWithText(TabChips, title), findsOneWidget, reason: title);
    }
    expect(find.text('Inbox'), findsNothing);
    expect(find.text('2'), findsOneWidget, reason: "Mail's count, closed");
  });

  testWidgets('a tap on the open site on screen asks to close it',
      (tester) async {
    final log = await pumpStrip(tester, sites: [docs, mail]);
    await tester.tap(find.text('Docs'));
    await tester.pump();
    expect(log.shown, 1);
  });

  testWidgets("another site's arrow opens it without switching",
      (tester) async {
    final log = await pumpStrip(tester, sites: [docs, mail]);
    await tester.tap(find.byTooltip("Show Mail's tabs"));
    await tester.pump();
    expect(log.toggled, [mail.siteId]);
  });

  testWidgets('an opened site shows its tabs beside the one on screen',
      (tester) async {
    await pumpStrip(tester,
        sites: [docs, mail], open: OpenSites(opened: {mail.siteId}));
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Q3 plan'), findsOneWidget);
  });

  testWidgets('a tab chip opens its tab, its cross closes it, + adds one',
      (tester) async {
    final log = await pumpStrip(tester, sites: [docs, mail]);
    await tester.tap(find.text('Budget 2027'));
    await tester.pump();
    expect(log.openedTabs, ['Docs/${docs.tabs[1].id}']);
    await tester.tap(find.descendant(
        of: find.widgetWithText(TabChip, 'Budget 2027'),
        matching: find.byTooltip('Close tab')));
    await tester.pump();
    expect(log.closed, ['Docs/${docs.tabs[1].id}']);
    await tester.tap(find.byTooltip('New tab'));
    await tester.pump();
    expect(log.added, ['Docs']);
  });

  testWidgets('a tab opened from another carries a mark', (tester) async {
    await pumpStrip(tester, sites: [docs, mail]);
    expect(
        find.descendant(
            of: find.widgetWithText(TabChip, 'Q3 plan'),
            matching: find.byKey(TabChip.openedFromMark)),
        findsNothing);
    expect(
        find.descendant(
            of: find.widgetWithText(TabChip, 'Budget 2027'),
            matching: find.byKey(TabChip.openedFromMark)),
        findsOneWidget);
  });
}
