import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/tab_chips.dart';

import 'helpers/localized.dart';
import 'helpers/model_fixture.dart';
import 'helpers/real_app.dart';

/// Touch targets meet the platform floor: every tappable node of the shipped
/// chrome on screen is at least 48x48 (Android) and 44x44 (iOS), as Flutter's
/// own guidelines measure it, while what is drawn inside may stay smaller.
///
/// The guidelines read semantics, so a control left out of them is not held
/// here: the drawer tile's corner menu (24, behind `ExcludeSemantics`) is
/// owed in openspec/unverified.tsv, as are the sidebar's squares and rail,
/// which no test here opens.
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
        withTabs('Docs', titles: ['Q3 plan', 'Budget 2027', 'Notes']),
        withTabs('Mail', titles: ['Inbox', 'Re: Q3 plan']),
        for (var i = 0; i < 6; i++)
          WebViewModel(initUrl: 'https://s$i.test', name: 'S$i'),
      ];

  Future<void> meetsFloors(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
  }

  Future<void> start(WidgetTester tester,
      {required Size size, Map<String, Object> prefs = const {}}) async {
    setViewSize(tester, size: size);
    await pumpRealApp(tester, sites: sites(), prefs: prefs);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Docs');
  }

  const phone = Size(400, 800);

  testWidgets('touch targets: the app bar and its tab counter', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester, size: phone);
    expect(find.byTooltip('Tabs'), findsOneWidget);
    await meetsFloors(tester);
    semantics.dispose();
  });

  testWidgets('touch targets: the drawer', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester, size: phone);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    expect(find.byType(Drawer), findsOneWidget);
    await meetsFloors(tester);
    semantics.dispose();
  });

  for (final size in [phone, const Size(1200, 800)]) {
    testWidgets('touch targets: the tab strip at ${size.width.round()} wide',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await start(tester,
          size: size,
          prefs: {'siteNavigation': 'strip', 'siteStripHidden': false});
      expect(find.byType(TabChip), findsWidgets);
      await meetsFloors(tester);
      final arrow = find.byTooltip("Show Mail's tabs");
      if (arrow.evaluate().isNotEmpty) {
        await tester.tap(arrow);
        await settleRealApp(tester);
        await meetsFloors(tester);
      }
      semantics.dispose();
    });
  }

  testWidgets('touch targets: the tabs sheet, this site and all sites',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester, size: phone);
    await openTabsSheet(tester);
    await meetsFloors(tester);
    await tester.tap(find.text('All sites'));
    await settleRealApp(tester);
    await meetsFloors(tester);
    semantics.dispose();
  });

  Future<void> meetsFloorsScrolled(WidgetTester tester) async {
    await meetsFloors(tester);
    for (var i = 0; i < 8; i++) {
      final list = find.byType(Scrollable);
      if (list.evaluate().isEmpty) return;
      await tester.drag(list.last, const Offset(0, -500));
      await settleRealApp(tester);
      await meetsFloors(tester);
    }
  }

  testWidgets('touch targets: App Settings and each of its screens',
      (tester) async {
    final semantics = tester.ensureSemantics();
    setViewSize(tester, size: phone);
    await pumpRealApp(tester, sites: sites(), prefs: {'developerMode': true});
    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    await meetsFloorsScrolled(tester);
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
      await meetsFloorsScrolled(tester);
      await tester.pageBack();
      await settleRealApp(tester);
    }
    semantics.dispose();
  });

  testWidgets('touch targets: a site\'s settings', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester, size: phone);
    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
    await settleRealApp(tester);
    await meetsFloors(tester);
    await tester.tap(find.text('Settings').last);
    await settleRealApp(tester);
    await meetsFloorsScrolled(tester);
    semantics.dispose();
  });

  testWidgets('touch targets: the proxy status check-again button',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final service = ProxyHealthService(
        probe: (_) async => const ProxyTestResult(ProxyTestOutcome.reachable));
    await pumpLocalized(tester,
        size: phone,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ProxyStatusIndicator(
              service: service,
              proxy: UserProxySettings(
                  type: ProxyType.SOCKS5, address: '10.0.0.1:1080'),
            ),
          ),
        ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Check again'), findsOneWidget);
    await meetsFloors(tester);
    semantics.dispose();
  });
}
