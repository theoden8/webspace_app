import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/hint_button.dart';

SiteBehaviourValues _values({
  bool alwaysOpenHome = false,
  bool kioskMode = false,
  bool fullscreenMode = false,
  bool tabsEnabled = true,
  bool htmlCaching = false,
  ExternalLinkMode externalLinkMode = ExternalLinkMode.inApp,
  bool routeOutboundLinks = false,
  List<OutboundPreference> outboundPreferences = const [],
  String? searchAddress,
  bool searchesWeb = false,
  List<String> searchSites = const [],
  String? searchDefault,
}) =>
    SiteBehaviourValues(
      alwaysOpenHome: alwaysOpenHome,
      kioskMode: kioskMode,
      fullscreenMode: fullscreenMode,
      tabsEnabled: tabsEnabled,
      htmlCachingEnabled: htmlCaching,
      externalLinkMode: externalLinkMode,
      routeOutboundLinks: routeOutboundLinks,
      outboundPreferences: outboundPreferences,
      searchAddress: searchAddress,
      searchesWeb: searchesWeb,
      searchSites: searchSites,
      searchDefault: searchDefault,
    );

Future<void> _pump(
  WidgetTester tester, {
  required SiteBehaviourValues values,
  bool incognito = false,
  Widget? domainClaims,
  ValueChanged<SiteBehaviourValues>? onChanged,
  bool containersActive = true,
  List<WebViewModel> routingTargets = const [],
  bool tabsAvailable = false,
  String? initUrl,
  String? discoveredSearchAddress,
  bool discoveredSearchesWeb = false,
}) async {
  // Tall surface so every row is laid out: the screen is one list and the
  // assertions below compare rows that sit at opposite ends of it.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SiteBehaviourScreen(
      host: 'example.com',
      incognito: incognito,
      values: values,
      domainClaims: domainClaims,
      onChanged: onChanged ?? (_) {},
      containersActive: containersActive,
      routingTargets: routingTargets,
      tabsAvailable: tabsAvailable,
      initUrl: initUrl,
      discoveredSearchAddress: discoveredSearchAddress,
      discoveredSearchesWeb: discoveredSearchesWeb,
    ),
  ));
  await tester.pumpAndSettle();
}

SwitchListTile _switchTitled(WidgetTester tester, String title) {
  final tile = find.ancestor(
    of: find.text(title),
    matching: find.byType(SwitchListTile),
  );
  expect(tile, findsOneWidget, reason: 'no switch titled "$title"');
  return tester.widget<SwitchListTile>(tile);
}

Finder get _modeDropdown => find.byType(DropdownButton<ExternalLinkMode>);

ExternalLinkMode? _selectedMode(WidgetTester tester) =>
    tester.widget<DropdownButton<ExternalLinkMode>>(_modeDropdown).value;

Future<void> _pickMode(WidgetTester tester, String label) async {
  await tester.tap(_modeDropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('SiteBehaviourValues', () {
    test('routing counts only in the in-app mode', () {
      final on = _values(routeOutboundLinks: true);
      expect(on.effectiveRouteOutboundLinks, isTrue);
      for (final mode in [ExternalLinkMode.browser, ExternalLinkMode.block]) {
        final other = on.copyWith(externalLinkMode: mode);
        expect(other.effectiveRouteOutboundLinks, isFalse, reason: mode.name);
        expect(other.routeOutboundLinks, isTrue);
      }
    });

    test('kiosk turns tabs off without overwriting them, full screen does '
        'not', () {
      expect(_values().effectiveTabsEnabled, isTrue);
      expect(_values(kioskMode: true).effectiveTabsEnabled, isFalse);
      expect(_values(kioskMode: true).tabsEnabled, isTrue);
      expect(_values(fullscreenMode: true).effectiveTabsEnabled, isTrue);
      expect(_values(tabsEnabled: false).effectiveTabsEnabled, isFalse);
    });

    test('incognito forces Always open Home without overwriting it', () {
      final stored = _values();
      expect(stored.effectiveAlwaysOpenHome(false), isFalse);
      expect(stored.effectiveAlwaysOpenHome(true), isTrue);
      // The stored value survives, so leaving incognito restores the user's
      // own choice rather than silently keeping the forced one.
      expect(
        stored.copyWith(alwaysOpenHome: true).effectiveAlwaysOpenHome(false),
        isTrue,
      );
    });
  });

  testWidgets('every behaviour switch lives on this screen', (tester) async {
    await _pump(tester, values: _values());
    for (final title in const [
      'Always open Home',
      'Kiosk mode',
      'Full screen mode',
      'HTML caching',
      'Route links to my sites',
    ]) {
      expect(_switchTitled(tester, title).onChanged, isNotNull, reason: title);
    }
    expect(find.text('Opening and display'), findsOneWidget);
    expect(find.text('Link handling'), findsOneWidget);
    expect(find.text('Open external links in browser'), findsNothing,
        reason: 'the switch became the browser option of External links');
    expect(find.text('Block auto-redirects'), findsNothing,
        reason: 'every site blocks them; there is nothing to switch');
  });

  group('external links (BEHAV-004)', () {
    testWidgets('a dropdown of three, explained behind its hint',
        (tester) async {
      await _pump(tester, values: _values());
      final dropdown =
          tester.widget<DropdownButton<ExternalLinkMode>>(_modeDropdown);
      expect(dropdown.items!.map((i) => i.value), ExternalLinkMode.values);
      expect(_selectedMode(tester), ExternalLinkMode.inApp);
      expect(find.text('Open in the app'), findsOneWidget);
      final header = find.ancestor(
        of: find.text('External links'),
        matching: find.byType(ListTile),
      );
      final hint = tester.widget<HintButton>(
          find.descendant(of: header, matching: find.byType(HintButton)));
      expect(hint.title, 'External links');
      expect(tester.widget<ListTile>(header).subtitle, isNull);
    });

    testWidgets('the longest locale fits a phone without overflow',
        (tester) async {
      // Greek has the longest option label (32 characters); the closed
      // dropdown is capped and ellipsised, so the title keeps its room.
      tester.view.physicalSize = const Size(360, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('el'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SiteBehaviourScreen(
          host: 'example.com',
          incognito: false,
          values: _values(externalLinkMode: ExternalLinkMode.browser),
          onChanged: (_) {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_selectedMode(tester), ExternalLinkMode.browser);
    });

    testWidgets('the stored mode is the one selected', (tester) async {
      await _pump(tester,
          values: _values(externalLinkMode: ExternalLinkMode.block));
      expect(_selectedMode(tester), ExternalLinkMode.block);
    });

    testWidgets('picking an option reports the whole value back',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(kioskMode: true),
        onChanged: (v) => seen = v,
      );
      await _pickMode(tester, 'Block');
      expect(seen!.externalLinkMode, ExternalLinkMode.block);
      expect(seen!.kioskMode, isTrue);
      expect(_selectedMode(tester), ExternalLinkMode.block);
    });
  });

  testWidgets('Always open Home reads as forced under incognito',
      (tester) async {
    await _pump(tester, values: _values(), incognito: true);
    final tile = _switchTitled(tester, 'Always open Home');
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNull);
    expect(find.text('Forced on by Incognito'), findsOneWidget);
  });

  testWidgets('toggling a row reports the whole value back', (tester) async {
    SiteBehaviourValues? seen;
    await _pump(
      tester,
      values: _values(kioskMode: true),
      onChanged: (v) => seen = v,
    );
    await tester.tap(find.text('Full screen mode'));
    await tester.pumpAndSettle();
    expect(seen, isNotNull);
    expect(seen!.fullscreenMode, isTrue);
    // Unrelated fields ride along untouched: the caller applies one value.
    expect(seen!.kioskMode, isTrue);
  });

  group('Tabs (TAB-013)', () {
    testWidgets('the row exists only while tabs are available',
        (tester) async {
      await _pump(tester, values: _values());
      expect(find.text('Tabs'), findsNothing);
      await _pump(tester, values: _values(), tabsAvailable: true);
      expect(_switchTitled(tester, 'Tabs').value, isTrue);
    });

    testWidgets('turning tabs on turns kiosk off and leaves full screen',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(kioskMode: true, fullscreenMode: true),
        tabsAvailable: true,
        onChanged: (v) => seen = v,
      );
      expect(_switchTitled(tester, 'Tabs').value, isFalse);
      await tester.tap(find.text('Tabs'));
      await tester.pumpAndSettle();
      expect(seen!.tabsEnabled, isTrue);
      expect(seen!.kioskMode, isFalse);
      expect(seen!.fullscreenMode, isTrue);
      expect(_switchTitled(tester, 'Tabs').value, isTrue);
      expect(_switchTitled(tester, 'Kiosk mode').value, isFalse);
      expect(_switchTitled(tester, 'Full screen mode').value, isTrue);
    });

    testWidgets('kiosk shows tabs off and gives them back', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(),
        tabsAvailable: true,
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('Kiosk mode'));
      await tester.pumpAndSettle();
      expect(_switchTitled(tester, 'Tabs').value, isFalse);
      expect(seen!.tabsEnabled, isTrue, reason: 'the stored choice is kept');
      await tester.tap(find.text('Kiosk mode'));
      await tester.pumpAndSettle();
      expect(_switchTitled(tester, 'Tabs').value, isTrue);
    });

    testWidgets('full screen leaves tabs on', (tester) async {
      await _pump(tester, values: _values(), tabsAvailable: true);
      await tester.tap(find.text('Full screen mode'));
      await tester.pumpAndSettle();
      expect(_switchTitled(tester, 'Tabs').value, isTrue);
    });

    testWidgets('turning tabs off leaves kiosk and full screen alone',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(),
        tabsAvailable: true,
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('Tabs'));
      await tester.pumpAndSettle();
      expect(seen!.tabsEnabled, isFalse);
      expect(seen!.kioskMode, isFalse);
      expect(seen!.fullscreenMode, isFalse);
    });
  });

  testWidgets('the domain-claim editor renders in the link group',
      (tester) async {
    await _pump(
      tester,
      values: _values(),
      domainClaims: const Text('claims-slot'),
    );
    // Below the external-links choice, whose hint points the reader at it.
    final claims = tester.getTopLeft(find.text('claims-slot')).dy;
    final choice = tester.getTopLeft(find.text('External links')).dy;
    expect(claims, greaterThan(choice));
  });

  group('outbound routing (BEHAV-003)', () {
    final gh = WebViewModel(
      siteId: 'gh',
      initUrl: 'https://github.com/',
      name: 'Work GitHub',
    );
    final pref = OutboundPreference(
      claim: DomainClaim.exactHost('github.com'),
      targetSiteId: 'gh',
    );

    testWidgets('the switch is an option of opening links in the app',
        (tester) async {
      await _pump(tester, values: _values());
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      double x(String t) => tester.getTopLeft(find.text(t)).dx;
      expect(y('Route links to my sites'), greaterThan(y('External links')));
      expect(x('Route links to my sites'), greaterThan(x('External links')),
          reason: 'indented under the choice it belongs to');
      final tile = find.ancestor(
        of: find.text('Route links to my sites'),
        matching: find.byType(SwitchListTile),
      );
      expect(tester.widget<SwitchListTile>(tile).subtitle, isNull);
      expect(
        find.descendant(of: tile, matching: find.byType(HintButton)),
        findsOneWidget,
      );
    });

    testWidgets('the rows need no developer mode', (tester) async {
      DeveloperModeService.instance.debugSet(false);
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true, outboundPreferences: [pref]),
        routingTargets: [gh],
      );
      expect(_switchTitled(tester, 'Route links to my sites').value, isTrue);
      expect(find.text('1 preference'), findsOneWidget);
    });

    for (final mode in [ExternalLinkMode.browser, ExternalLinkMode.block]) {
      testWidgets('the ${mode.name} mode hides both rows', (tester) async {
        await _pump(
          tester,
          values: _values(
            externalLinkMode: mode,
            routeOutboundLinks: true,
            outboundPreferences: [pref],
          ),
          routingTargets: [gh],
        );
        expect(find.text('Route links to my sites'), findsNothing);
        expect(find.text('Routing preferences'), findsNothing);
      });
    }

    testWidgets('leaving the in-app mode keeps the routing switch',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true),
        onChanged: (v) => seen = v,
      );
      await _pickMode(tester, 'Open in browser');
      expect(find.text('Route links to my sites'), findsNothing);
      expect(seen!.routeOutboundLinks, isTrue);
      await _pickMode(tester, 'Open in the app');
      expect(_switchTitled(tester, 'Route links to my sites').value, isTrue);
    });

    testWidgets('the legacy engine disables it with the reason',
        (tester) async {
      await _pump(tester, values: _values(), containersActive: false);
      expect(_switchTitled(tester, 'Route links to my sites').onChanged,
          isNull);
      expect(find.text('Needs per-site containers'), findsOneWidget);
    });

    testWidgets('the preferences row shows only while routing is on',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(tester, values: _values(), onChanged: (v) => seen = v);
      expect(find.text('Routing preferences'), findsNothing);
      await tester.tap(find.text('Route links to my sites'));
      await tester.pumpAndSettle();
      expect(seen!.routeOutboundLinks, isTrue);
      expect(find.text('Routing preferences'), findsOneWidget);
      expect(find.text('Global routing only'), findsOneWidget);
    });

    testWidgets('the preferences row counts the list', (tester) async {
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true, outboundPreferences: [pref]),
        routingTargets: [gh],
      );
      expect(find.text('1 preference'), findsOneWidget);
      await tester.tap(find.text('Routing preferences'));
      await tester.pumpAndSettle();
      expect(find.text('github.com'), findsOneWidget);
      expect(find.text('Opens as Work GitHub'), findsOneWidget);
    });

    testWidgets('a preference is added through the dialog', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true),
        routingTargets: [gh],
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('Routing preferences'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add routing preference'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'github.com');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(seen!.outboundPreferences, [pref]);
      expect(find.text('Opens as Work GitHub'), findsOneWidget);
    });

    testWidgets('a claim that already routes somewhere is refused',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true, outboundPreferences: [pref]),
        routingTargets: [gh],
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('Routing preferences'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add routing preference'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'github.com');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Already routes to Work GitHub'), findsOneWidget);
      expect(seen, isNull);
    });

    testWidgets('with no other site there is nothing to add',
        (tester) async {
      await _pump(tester, values: _values(routeOutboundLinks: true));
      await tester.tap(find.text('Routing preferences'));
      await tester.pumpAndSettle();
      final add = tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(Icons.add),
        matching: find.byType(IconButton),
      ));
      expect(add.onPressed, isNull);
    });
  });

  group('BEHAV-005 search group', () {
    final ddg = WebViewModel(
        siteId: 'ddg', initUrl: 'https://duckduckgo.com/', name: 'DuckDuckGo');
    final kagi =
        WebViewModel(siteId: 'kagi', initUrl: 'https://kagi.com/', name: 'Kagi');

    testWidgets('the group is offered only with the Site tabs switch (LIR-029)',
        (tester) async {
      await _pump(tester, values: _values(), initUrl: 'https://github.com/');
      expect(find.text('Search'), findsNothing);
      expect(find.text('Default search from this site'), findsNothing);
      expect(find.text('Search sites offered'), findsNothing);
    });

    testWidgets('a known site shows its address and follows the app',
        (tester) async {
      await _pump(tester,
          values: _values(), initUrl: 'https://github.com/', tabsAvailable: true);
      expect(find.text('https://github.com/search?q=%s'), findsOneWidget);
      expect(find.text('App default'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
    });

    testWidgets('saving a known engine\'s address unchanged stores nothing',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        tabsAvailable: true,
        values: _values(),
        initUrl: 'https://duckduckgo.com/',
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('https://duckduckgo.com/?q=%s'));
      await tester.pumpAndSettle();
      expect(_switchTitled(tester, 'Searches the whole web').value, isTrue);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(seen!.searchAddress, isNull);
      expect(seen!.searchesWeb, isFalse);
    });

    testWidgets('Reset returns to the known address', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        tabsAvailable: true,
        values: _values(
            searchAddress: 'https://github.com/search?type=code&q=%s'),
        initUrl: 'https://github.com/',
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('https://github.com/search?type=code&q=%s'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(seen!.searchAddress, isNull);
      expect(find.text('https://github.com/search?q=%s'), findsOneWidget);
    });

    testWidgets('an address the site\'s pages declared shows as its own',
        (tester) async {
      await _pump(
        tester,
        tabsAvailable: true,
        values: _values(),
        initUrl: 'https://searx.lan/',
        discoveredSearchAddress: 'https://searx.lan/search?q=%s',
        discoveredSearchesWeb: true,
      );
      expect(find.text('https://searx.lan/search?q=%s'), findsOneWidget);
      await tester.tap(find.text('https://searx.lan/search?q=%s'));
      await tester.pumpAndSettle();
      expect(_switchTitled(tester, 'Searches the whole web').value, isTrue);
    });

    testWidgets('pickers tell same-named sites apart by id (LIR-029)',
        (tester) async {
      final work = WebViewModel(
          siteId: 'ddg-work',
          initUrl: 'https://duckduckgo.com/',
          name: 'DuckDuckGo')
        ..containerColor = 1;
      final home = WebViewModel(
          siteId: 'ddg-home',
          initUrl: 'https://duckduckgo.com/',
          name: 'DuckDuckGo')
        ..containerColor = 6;
      await _pump(tester,
          tabsAvailable: true, values: _values(), routingTargets: [work, home]);
      await tester.tap(find.text('Default search from this site'));
      await tester.pumpAndSettle();
      expect(find.text('ddg-work'), findsOneWidget);
      expect(find.text('ddg-home'), findsOneWidget);
      expect(
        tester
            .widget<SiteIdLine>(find.ancestor(
                of: find.text('ddg-home'), matching: find.byType(SiteIdLine)))
            .colorIndex,
        6,
      );
      Navigator.of(tester.element(find.text('ddg-home'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Search sites offered'));
      await tester.pumpAndSettle();
      expect(find.text('ddg-work'), findsOneWidget);
      expect(find.text('ddg-home'), findsOneWidget);
    });

    testWidgets('the legacy engine shows ids without container colours',
        (tester) async {
      final ddg = WebViewModel(
          siteId: 'ddg', initUrl: 'https://duckduckgo.com/', name: 'DuckDuckGo')
        ..containerColor = 1;
      await _pump(tester,
          tabsAvailable: true,
          containersActive: false,
          values: _values(),
          routingTargets: [ddg]);
      await tester.tap(find.text('Default search from this site'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SiteIdLine>(find.ancestor(
                of: find.text('ddg'), matching: find.byType(SiteIdLine)))
            .colorIndex,
        isNull,
      );
    });

    testWidgets('a list that drops the default clears it', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        tabsAvailable: true,
        values: _values(searchDefault: 'kagi'),
        routingTargets: [ddg, kagi],
        onChanged: (v) => seen = v,
      );
      expect(find.text('Kagi'), findsOneWidget);
      await tester.tap(find.text('Search sites offered'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'DuckDuckGo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(seen!.searchSites, ['ddg']);
      expect(seen!.searchDefault, isNull);
      expect(find.text('App default'), findsOneWidget);
    });
  });
}
