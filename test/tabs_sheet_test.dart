import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart';

/// A site with [urls] as tabs. The first is the active one; every later tab is
/// a child of the one before it, so the fixture is a chain three deep.
WebViewModel siteWithChain(String name, List<String> urls) {
  final m = WebViewModel(initUrl: urls.first, name: name);
  var parent = m.activeTabId;
  for (final url in urls.skip(1)) {
    final t = SiteTab(id: 'tab${m.tabs.length}', url: url, parentId: parent);
    m.tabs = [...m.tabs, t];
    parent = t.id;
  }
  return m;
}

Future<void> pumpSheet(
  WidgetTester tester,
  List<TabsSheetSite> sites, {
  void Function(int, String)? onOpenTab,
  void Function(int)? onNewTab,
  void Function(int, String)? onCloseTab,
  void Function(int, String)? onCloseSubtree,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: TabsSheet(
        sites: sites,
        currentIndex: 0,
        onOpenTab: onOpenTab ?? (_, _) {},
        onNewTab: onNewTab ?? (_) {},
        onCloseTab: onCloseTab ?? (_, _) {},
        onCloseSubtree: onCloseSubtree ?? (_, _) {},
      ),
    ),
  ));
  await tester.pump();
}

/// How strongly the row showing [text] is drawn: 1 for a tab that holds a
/// webview, faded for a stored one (TAB-011).
double strengthOf(WidgetTester tester, String text) => tester
    .widget<Opacity>(find
        .ancestor(of: find.text(text).first, matching: find.byType(Opacity))
        .first)
    .opacity;

/// Whether the row showing [text] carries the selected-row highlight that
/// marks the tab on screen.
bool isHighlighted(String text) => find
    .ancestor(of: find.text(text).first, matching: find.byType(Ink))
    .evaluate()
    .isNotEmpty;

void main() {
  group('TAB-008 — the tab list', () {
    testWidgets('lists every tab of the site, with the open one selected',
        (tester) async {
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ]);

      expect(find.textContaining('github.com'), findsWidgets);
      expect(find.text('GitHub · 3 tabs'), findsOneWidget);
      // Exactly one row is the loaded one: the active tab of the site on
      // screen. Every other tab is stored, not running.
      expect(strengthOf(tester, 'https://github.com/'), 1);
      expect(isHighlighted('https://github.com/'), isTrue);
      for (final stored in [
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]) {
        expect(strengthOf(tester, stored), lessThan(1));
        expect(isHighlighted(stored), isFalse);
      }
      expect(find.text('open'), findsNothing);
    });

    testWidgets('a site on one tab says so in the singular', (tester) async {
      final site = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ]);
      expect(find.text('Mastodon · 1 tab'), findsOneWidget);
    });

    testWidgets('collapsing a tab hides the tabs opened from it',
        (tester) async {
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
        'https://github.com/pull/601',
      ]);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true),
      ]);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
      await tester.pump();

      // The whole subtree goes, not just the direct child.
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.text('2 tabs hidden'), findsOneWidget);
    });

    testWidgets('New tab reports the site it belongs to', (tester) async {
      int? opened;
      final site = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 7, model: site, isCurrent: true, isLoaded: true)],
        onNewTab: (i) => opened = i,
      );
      await tester.tap(find.text('New tab'));
      await tester.pump();
      expect(opened, 7);
    });

    testWidgets('closing a row reports that tab', (tester) async {
      String? closed;
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true)],
        onCloseTab: (_, id) => closed = id,
      );
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(closed, site.tabs.last.id);
    });

    testWidgets('a tab with children offers closing the subtree',
        (tester) async {
      String? closed;
      final site = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      await pumpSheet(
        tester,
        [TabsSheetSite(index: 0, model: site, isCurrent: true, isLoaded: true)],
        onCloseSubtree: (_, id) => closed = id,
      );
      // Only the parent row has the control: the leaf has nothing under it.
      expect(find.byIcon(Icons.layers_clear_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.layers_clear_outlined));
      await tester.pump();
      expect(closed, site.tabs.first.id);
    });

    testWidgets('the all-sites scope appears only with more than one site',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
      ]);
      expect(find.text('All sites'), findsNothing);

      final b = siteWithChain('Mastodon', ['https://mastodon.social/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
        TabsSheetSite(index: 1, model: b, isCurrent: false, isLoaded: false),
      ]);
      expect(find.text('All sites'), findsOneWidget);
      expect(find.text('This site'), findsOneWidget);

      await tester.tap(find.text('All sites'));
      await tester.pump();
      // Both sites' headings are present once the scope widens.
      expect(find.text('GitHub · 1 tab'), findsWidgets);
      expect(find.text('Mastodon · 1 tab'), findsOneWidget);
    });

    testWidgets('TAB-011 — a tab is faded unless the load policy holds it',
        (tester) async {
      final a = siteWithChain('GitHub', [
        'https://github.com/',
        'https://github.com/pulls',
      ]);
      final b = siteWithChain('Mastodon', [
        'https://mastodon.social/',
        'https://mastodon.social/@a',
      ]);
      final c = siteWithChain('Wikipedia', ['https://en.wikipedia.org/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: true),
        // Backgrounded but still resident: its active tab keeps a paused
        // webview until the policy evicts the site.
        TabsSheetSite(index: 1, model: b, isCurrent: false, isLoaded: true),
        // Unloaded by the policy: nothing of it is in memory.
        TabsSheetSite(index: 2, model: c, isCurrent: false, isLoaded: false),
      ]);
      await tester.tap(find.text('All sites'));
      await tester.pump();
      // One tab per loaded site holds a webview, never more (TAB-002), and
      // only the one on screen is selected.
      expect(strengthOf(tester, 'https://github.com/'), 1);
      expect(isHighlighted('https://github.com/'), isTrue);
      expect(strengthOf(tester, 'https://mastodon.social/'), 1);
      expect(isHighlighted('https://mastodon.social/'), isFalse);
      // Each site's other tabs, and every tab of the unloaded site, are
      // stored and faded.
      expect(strengthOf(tester, 'https://github.com/pulls'), lessThan(1));
      expect(strengthOf(tester, 'https://mastodon.social/@a'), lessThan(1));
      expect(strengthOf(tester, 'https://en.wikipedia.org/'), lessThan(1));
      // The fade has no words on screen; a screen reader gets them instead.
      expect(find.text('open'), findsNothing);
      expect(find.text('loaded'), findsNothing);
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(find
          .ancestor(
              of: find.text('https://mastodon.social/').first,
              matching: find.byType(Semantics))
          .first);
      expect(node.value, 'loaded');
      handle.dispose();
    });

    testWidgets('the site on screen but not yet built draws its tab faded',
        (tester) async {
      final a = siteWithChain('GitHub', ['https://github.com/']);
      await pumpSheet(tester, [
        TabsSheetSite(index: 0, model: a, isCurrent: true, isLoaded: false),
      ]);
      expect(strengthOf(tester, 'https://github.com/'), lessThan(1));
      expect(isHighlighted('https://github.com/'), isFalse);
    });
  });
}
