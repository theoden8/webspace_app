import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/hint_button.dart';

SiteBehaviourValues _values({
  bool archived = false,
  bool alwaysOpenHome = false,
  bool kioskMode = false,
  bool fullscreenMode = false,
  bool? tabsEnabled = true,
  bool htmlCaching = false,
  ExternalLinkMode? externalLinkMode = ExternalLinkMode.inApp,
  bool routeOutboundLinks = false,
  List<OutboundPreference> outboundPreferences = const [],
  String? searchAddress,
  bool searchesWeb = false,
  List<SiteId> searchSites = const [],
  SiteId? searchDefault,
}) =>
    SiteBehaviourValues(
      archived: archived,
      alwaysOpenHome: alwaysOpenHome,
      kioskMode: kioskMode,
      fullscreenMode: fullscreenMode,
      tabsEnabled: Scoped.fromStored(tabsEnabled),
      htmlCachingEnabled: htmlCaching,
      externalLinkMode: Scoped.fromStored(externalLinkMode),
      routeOutboundLinks: routeOutboundLinks,
      outboundPreferences: outboundPreferences,
      searchAddress: searchAddress,
      searchesWeb: searchesWeb,
      searchSites: searchSites,
      searchDefault: Scoped.fromStored(searchDefault),
    );

Future<void> _pump(
  WidgetTester tester, {
  required SiteBehaviourValues values,
  bool incognito = false,
  Widget? domainClaims,
  ValueChanged<SiteBehaviourValues>? onChanged,
  bool containersActive = true,
  List<WebViewModel> routingTargets = const [],
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
      initUrl: initUrl,
      discoveredSearchAddress: discoveredSearchAddress,
      discoveredSearchesWeb: discoveredSearchesWeb,
    ),
  ));
  await tester.pumpAndSettle();
}

SwitchListTile _switchTitled(WidgetTester tester, {required String title}) {
  final tile = find.ancestor(
    of: find.text(title),
    matching: find.byType(SwitchListTile),
  );
  expect(tile, findsOneWidget, reason: 'no switch titled "$title"');
  return tester.widget<SwitchListTile>(tile);
}

Finder get _modeDropdown => find.byType(DropdownButton<Scoped<ExternalLinkMode>>);

ExternalLinkMode? _selectedMode(WidgetTester tester) =>
    tester.widget<DropdownButton<Scoped<ExternalLinkMode>>>(_modeDropdown).value?.stored;

Future<void> _pickMode(WidgetTester tester, {required String label}) async {
  await tester.tap(_modeDropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Finder get _tabsTile => find.ancestor(
      of: find.text('Tabs'), matching: find.byType(ListTile));

Finder get _tabsSwitch => find.descendant(
      of: _tabsTile, matching: find.byType(Switch));

Finder get _routingTile => find.ancestor(
      of: find.text('Route links to my sites'),
      matching: find.byType(SwitchListTile));

Finder get _routingSwitch => find.descendant(
      of: _routingTile, matching: find.byType(Switch));

bool _selectedRouting(WidgetTester tester) =>
    tester.widget<Switch>(_routingSwitch).value;

Future<void> _tapRouting(WidgetTester tester) async {
  await tester.tap(_routingSwitch);
  await tester.pumpAndSettle();
}

bool _selectedTabs(WidgetTester tester) =>
    tester.widget<Switch>(_tabsSwitch).value;

Future<void> _tapTabs(WidgetTester tester) async {
  await tester.tap(_tabsSwitch);
  await tester.pumpAndSettle();
}

Future<void> _resetTabs(WidgetTester tester) async {
  await tester.longPress(_tabsSwitch);
  await tester.pumpAndSettle();
}


void main() {
  setUp(() {
    AppPref.tabsEnabled.debugValue = true;
    AppPref.externalLinkMode.debugValue = 'inApp';
    AppPref.routeOutboundLinks.debugValue = false;
  });
  tearDown(() {
    AppPref.tabsEnabled.debugValue = true;
    AppPref.externalLinkMode.debugValue = 'inApp';
    AppPref.routeOutboundLinks.debugValue = false;
  });

  group('SiteBehaviourValues', () {
    test('routing counts only in the in-app mode', () {
      final on = _values(routeOutboundLinks: true);
      expect(on.effectiveRouteOutboundLinks, isTrue);
      for (final mode in [ExternalLinkMode.browser, ExternalLinkMode.block]) {
        final other = on.copyWith(externalLinkMode: Own(mode));
        expect(other.effectiveRouteOutboundLinks, isFalse, reason: mode.name);
        expect(other.routeOutboundLinks, isTrue);
      }
    });

    test('kiosk turns tabs off without overwriting them, full screen does '
        'not', () {
      expect(_values().effectiveTabsEnabled, isTrue);
      expect(_values(kioskMode: true).effectiveTabsEnabled, isFalse);
      expect(_values(kioskMode: true).tabsEnabled.stored, isTrue);
      expect(_values(fullscreenMode: true).effectiveTabsEnabled, isTrue);
      expect(_values(tabsEnabled: false).effectiveTabsEnabled, isFalse);
    });

    test('incognito forces Always open Home without overwriting it', () {
      final stored = _values();
      expect(stored.effectiveAlwaysOpenHome(incognito: false), isFalse);
      expect(stored.effectiveAlwaysOpenHome(incognito: true), isTrue);
      // The stored value survives, so leaving incognito restores the user's
      // own choice rather than silently keeping the forced one.
      expect(
        stored
            .copyWith(alwaysOpenHome: true)
            .effectiveAlwaysOpenHome(incognito: false),
        isTrue,
      );
    });
  });

  testWidgets('every behaviour switch lives on this screen (BEHAV-001)', (tester) async {
    await _pump(tester, values: _values());
    for (final title in [
      'Always open Home',
      'Kiosk mode',
      'Full screen mode',
      if (engineLoadsCacheFirst) 'HTML caching',
    ]) {
      expect(_switchTitled(tester, title: title).onChanged, isNotNull,
          reason: title);
    }
    expect(_routingSwitch, findsOneWidget);
    if (!engineLoadsCacheFirst) {
      expect(find.text('HTML caching'), findsNothing,
          reason: 'this engine cannot load a page from its cache first');
    }
    expect(find.text('Opening and display'), findsOneWidget);
    expect(find.text('Link handling'), findsOneWidget);
    expect(find.text('Open external links in browser'), findsNothing,
        reason: 'the switch became the browser option of External links');
    expect(find.text('Block auto-redirects'), findsNothing,
        reason: 'every site blocks them; there is nothing to switch');
  });

  group('external links (BEHAV-004)', () {
    testWidgets('App default inherits routing and hides its saved override',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(tester, values: _values(routeOutboundLinks: true),
          onChanged: (v) => seen = v);
      expect(find.text('Routing preferences'), findsOneWidget);
      await _pickMode(tester, label: 'App default');
      expect(find.text('Route links to my sites'), findsNothing);
      expect(find.text('Routing preferences'), findsNothing);
      expect(seen!.routeOutboundLinks, isTrue);
      expect(seen!.effectiveRouteOutboundLinks, isFalse);
      AppPref.routeOutboundLinks.debugValue = true;
      await tester.pumpAndSettle();
      expect(seen!.effectiveRouteOutboundLinks, isTrue);
      expect(find.text('Route links to my sites'), findsNothing);
      AppPref.routeOutboundLinks.debugValue = false;
      await tester.pumpAndSettle();
      await _pickMode(tester, label: 'Open in the app');
      expect(_selectedRouting(tester), isTrue);
      expect(find.text('Routing preferences'), findsOneWidget);
    });

    testWidgets('returning to app default follows later changes', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(tester,
          values: _values(externalLinkMode: ExternalLinkMode.block),
          onChanged: (v) => seen = v);
      await _pickMode(tester, label: 'App default');
      expect(seen!.externalLinkMode, const FollowApp<ExternalLinkMode>());
      AppPref.externalLinkMode.debugValue = 'browser';
      await tester.pumpAndSettle();
      expect(seen!.effectiveExternalLinkMode, ExternalLinkMode.browser);
      expect(find.text('Open in browser'), findsOneWidget);
      expect(find.text('Route links to my sites'), findsNothing);
    });

    testWidgets('archive keeps inherited browser links in the app', (tester) async {
      AppPref.externalLinkMode.debugValue = 'browser';
      await _pump(tester, values: _values(archived: true, externalLinkMode: null));
      expect(_selectedMode(tester), isNull);
      expect(find.text('Open in the app'), findsOneWidget);
      expect(find.text('Route links to my sites'), findsNothing);
    });

    testWidgets('app default and three modes, explained behind its hint',
        (tester) async {
      await _pump(tester, values: _values());
      final dropdown =
          tester.widget<DropdownButton<Scoped<ExternalLinkMode>>>(_modeDropdown);
      expect(dropdown.items!.map((i) => i.value), [
        const FollowApp<ExternalLinkMode>(),
        for (final mode in ExternalLinkMode.values) Own(mode),
      ]);
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
          containersActive: true,
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
      await _pickMode(tester, label: 'Block');
      expect(seen!.externalLinkMode.stored, ExternalLinkMode.block);
      expect(seen!.kioskMode, isTrue);
      expect(_selectedMode(tester), ExternalLinkMode.block);
    });
  });

  testWidgets('Always open Home reads as forced under incognito',
      (tester) async {
    await _pump(tester, values: _values(), incognito: true);
    final tile = _switchTitled(tester, title: 'Always open Home');
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
    testWidgets('inheritance dims an enabled switch and long press restores it',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        SiteBehaviourValues? seen;
        var changes = 0;
        await _pump(tester, values: _values(tabsEnabled: null), onChanged: (v) {
          seen = v;
          changes++;
        });
        double opacity() => tester.widget<Opacity>(find.ancestor(
              of: _tabsSwitch, matching: find.byType(Opacity)).first).opacity;
        expect(opacity(), lessThan(1));
        expect(tester.widget<Switch>(_tabsSwitch).onChanged, isNotNull);
        expect(tester.getSemantics(_tabsTile).getSemanticsData()
            .hasAction(SemanticsAction.longPress), isTrue);
        await _tapTabs(tester);
        expect(seen!.tabsEnabled, const Own(false));
        expect(opacity(), 1);
        AppPref.tabsEnabled.debugValue = false;
        await tester.pumpAndSettle();
        expect(seen!.tabsEnabled, const Own(false),
            reason: 'matching the app does not clear an explicit choice');
        await _resetTabs(tester);
        expect(seen!.tabsEnabled, const FollowApp<bool>());
        expect(_selectedTabs(tester), isFalse);
        expect(opacity(), lessThan(1));
        expect(changes, 2, reason: 'releasing a long press must not also tap');
        await _resetTabs(tester);
        expect(seen!.tabsEnabled, const FollowApp<bool>());
        expect(_selectedTabs(tester), isFalse);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('returning to app default follows later changes', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(tester, values: _values(tabsEnabled: false),
          onChanged: (v) => seen = v);
      await _resetTabs(tester);
      expect(seen!.tabsEnabled, const FollowApp<bool>());
      AppPref.tabsEnabled.debugValue = false;
      await tester.pumpAndSettle();
      expect(_selectedTabs(tester), isFalse);
      expect(find.descendant(of: _tabsTile, matching: find.text('App default')),
          findsOneWidget);
    });

    testWidgets('a site has tabs unless it says otherwise', (tester) async {
      await _pump(tester, values: _values());
      expect(_selectedTabs(tester), isTrue);
    });

    testWidgets('turning tabs on turns kiosk off and leaves full screen',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(kioskMode: true, fullscreenMode: true),
        onChanged: (v) => seen = v,
      );
      expect(_selectedTabs(tester), isFalse);
      await _tapTabs(tester);
      expect(seen!.tabsEnabled.stored, isTrue);
      expect(seen!.kioskMode, isFalse);
      expect(seen!.fullscreenMode, isTrue);
      expect(_selectedTabs(tester), isTrue);
      expect(_switchTitled(tester, title: 'Kiosk mode').value, isFalse);
      expect(_switchTitled(tester, title: 'Full screen mode').value, isTrue);
    });

    testWidgets('kiosk shows tabs off and gives them back (BEHAV-005)', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(),
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('Kiosk mode'));
      await tester.pumpAndSettle();
      expect(_selectedTabs(tester), isFalse);
      expect(seen!.tabsEnabled.stored, isTrue, reason: 'the stored choice is kept');
      await tester.tap(find.text('Kiosk mode'));
      await tester.pumpAndSettle();
      expect(_selectedTabs(tester), isTrue);
    });

    testWidgets('full screen leaves tabs on', (tester) async {
      await _pump(tester, values: _values());
      await tester.tap(find.text('Full screen mode'));
      await tester.pumpAndSettle();
      expect(_selectedTabs(tester), isTrue);
    });

    testWidgets('turning tabs off leaves kiosk and full screen alone',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(),
        onChanged: (v) => seen = v,
      );
      await _tapTabs(tester);
      expect(seen!.tabsEnabled.stored, isFalse);
      expect(seen!.kioskMode, isFalse);
      expect(seen!.fullscreenMode, isFalse);
    });
  });

  group('Sign-in popups (NESTED-014, BEHAV-007)', () {
    Finder tile() => find.ancestor(
        of: find.text('Sign-in popups'), matching: find.byType(ListTile));
    Finder toggle() =>
        find.descendant(of: tile(), matching: find.byType(Switch));
    bool shown(WidgetTester tester) => tester.widget<Switch>(toggle()).value;

    setUp(() => PopupKind.debugSignInExperimental = false);
    tearDown(() {
      PopupKind.debugSignInExperimental = null;
      AppPref.signInPopups.debugValue = true;
    });

    testWidgets('a site follows the app dimmed until it makes its own choice',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(tester, values: _values(), onChanged: (v) => seen = v);
      double opacity() => tester.widget<Opacity>(find.ancestor(
            of: toggle(), matching: find.byType(Opacity)).first).opacity;
      expect(shown(tester), isTrue, reason: 'the app default is on');
      expect(opacity(), lessThan(1));
      expect(find.descendant(of: tile(), matching: find.text('App default')),
          findsOneWidget);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(seen!.signInPopups, const Own(false));
      expect(shown(tester), isFalse);
      expect(opacity(), 1);
      await tester.longPress(toggle());
      await tester.pumpAndSettle();
      expect(seen!.signInPopups, const FollowApp<bool>());
      AppPref.signInPopups.debugValue = false;
      await tester.pumpAndSettle();
      expect(shown(tester), isFalse, reason: "a following site shows the app's");
    });

    testWidgets('it sits in the link group, above the claims editor',
        (tester) async {
      await _pump(tester,
          values: _values(), domainClaims: const Text('claims-slot'));
      final row = tester.getTopLeft(find.text('Sign-in popups')).dy;
      expect(row, greaterThan(tester.getTopLeft(find.text('External links')).dy));
      expect(row, lessThan(tester.getTopLeft(find.text('claims-slot')).dy));
    });

    testWidgets('absent where the host does not offer them', (tester) async {
      PopupKind.debugSignInExperimental = true;
      await _pump(tester, values: _values());
      expect(find.text('Sign-in popups'), findsNothing);
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
      siteId: SiteId('gh'),
      initUrl: 'https://github.com/',
      name: 'Work GitHub',
    );
    final pref = OutboundPreference(
      claim: DomainClaim.exactHost('github.com'),
      targetSiteId: SiteId('gh'),
    );

    testWidgets('routing is a plain toggle independent of the app routing value',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        SiteBehaviourValues? seen;
        AppPref.routeOutboundLinks.debugValue = true;
        await _pump(tester, values: _values(), onChanged: (v) => seen = v);
        expect(_selectedRouting(tester), isFalse);
        expect(find.text('Routing preferences'), findsNothing);
        expect(tester.widget<Switch>(_routingSwitch).onChanged, isNotNull);
        expect(tester.getSemantics(_routingTile).getSemanticsData()
            .hasAction(SemanticsAction.longPress), isFalse);
        expect(find.descendant(of: _routingTile,
            matching: find.text('App default')), findsNothing);
        await _tapRouting(tester);
        expect(seen!.routeOutboundLinks, isTrue);
        expect(find.text('Routing preferences'), findsOneWidget);
        AppPref.routeOutboundLinks.debugValue = false;
        await tester.pumpAndSettle();
        expect(_selectedRouting(tester), isTrue);
        await _tapRouting(tester);
        expect(seen!.routeOutboundLinks, isFalse);
        expect(find.text('Routing preferences'), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('the toggle is an option of opening links in the app',
        (tester) async {
      await _pump(tester, values: _values());
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      double x(String t) => tester.getTopLeft(find.text(t)).dx;
      expect(y('Route links to my sites'), greaterThan(y('External links')));
      expect(x('Route links to my sites'), greaterThan(x('External links')),
          reason: 'indented under the choice it belongs to');
      final tile = find.ancestor(
        of: find.text('Route links to my sites'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(tile).subtitle, isNull);
      expect(
        find.descendant(of: tile, matching: find.byType(HintButton)),
        findsOneWidget,
      );
    });

    testWidgets('the rows need no developer mode', (tester) async {
      DeveloperModeService.instance.debugSet(on: false);
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true, outboundPreferences: [pref]),
        routingTargets: [gh],
      );
      expect(_selectedRouting(tester), isTrue);
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
      await _pickMode(tester, label: 'Open in browser');
      expect(find.text('Route links to my sites'), findsNothing);
      expect(seen!.routeOutboundLinks, isTrue);
      await _pickMode(tester, label: 'Open in the app');
      expect(_selectedRouting(tester), isTrue);
    });

    testWidgets('the legacy engine disables it with the reason',
        (tester) async {
      await _pump(tester, values: _values(), containersActive: false);
      final tile = find.ancestor(
        of: _routingSwitch, matching: find.byType(ListTile));
      expect(tester.widget<ListTile>(tile).enabled, isFalse);
      expect(find.text('Needs per-site containers'), findsOneWidget);
    });

    testWidgets('the preferences row shows only while routing is on',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(tester, values: _values(), onChanged: (v) => seen = v);
      expect(find.text('Routing preferences'), findsNothing);
      await _tapRouting(tester);
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

  group('BEHAV-006 search group', () {
    final ddg = WebViewModel(
        siteId: SiteId('ddg'), initUrl: 'https://duckduckgo.com/', name: 'DuckDuckGo');
    final kagi =
        WebViewModel(siteId: SiteId('kagi'), initUrl: 'https://kagi.com/', name: 'Kagi');

    // The Sign-in popups row also follows the app by default.
    Finder searchDefaultSays(String text) => find.descendant(
        of: find.ancestor(
            of: find.text('Default search from this site'),
            matching: find.byType(ListTile)),
        matching: find.text(text));

    testWidgets('the group needs no developer mode (LIR-029)', (tester) async {
      await _pump(tester, values: _values(), initUrl: 'https://github.com/');
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Default search from this site'), findsOneWidget);
      expect(find.text('Search sites offered'), findsOneWidget);
    });

    testWidgets('a known site shows its address and follows the app',
        (tester) async {
      await _pump(tester, values: _values(), initUrl: 'https://github.com/');
      expect(find.text('https://github.com/search?q=%s'), findsOneWidget);
      expect(searchDefaultSays('App default'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
    });

    testWidgets('saving a known engine\'s address unchanged stores nothing',
        (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
        values: _values(),
        initUrl: 'https://duckduckgo.com/',
        onChanged: (v) => seen = v,
      );
      await tester.tap(find.text('https://duckduckgo.com/?q=%s'));
      await tester.pumpAndSettle();
      expect(
          _switchTitled(tester, title: 'Searches the whole web').value, isTrue);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(seen!.searchAddress, isNull);
      expect(seen!.searchesWeb, isFalse);
    });

    testWidgets('Reset returns to the known address', (tester) async {
      SiteBehaviourValues? seen;
      await _pump(
        tester,
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
        values: _values(),
        initUrl: 'https://searx.lan/',
        discoveredSearchAddress: 'https://searx.lan/search?q=%s',
        discoveredSearchesWeb: true,
      );
      expect(find.text('https://searx.lan/search?q=%s'), findsOneWidget);
      await tester.tap(find.text('https://searx.lan/search?q=%s'));
      await tester.pumpAndSettle();
      expect(
          _switchTitled(tester, title: 'Searches the whole web').value, isTrue);
    });

    testWidgets('pickers tell same-named sites apart by id (LIR-029)',
        (tester) async {
      final work = WebViewModel(
          siteId: SiteId('ddg-work'),
          initUrl: 'https://duckduckgo.com/',
          name: 'DuckDuckGo')
        ..containerColor = 1;
      final home = WebViewModel(
          siteId: SiteId('ddg-home'),
          initUrl: 'https://duckduckgo.com/',
          name: 'DuckDuckGo')
        ..containerColor = 6;
      await _pump(tester,
          values: _values(searchSites: [SiteId('ddg-work'), SiteId('ddg-home')]),
          routingTargets: [work, home]);
      expect(find.text('DuckDuckGo (ddg-work), DuckDuckGo (ddg-home)'),
          findsOneWidget,
          reason: 'the summary names each site so the two read apart');
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
          siteId: SiteId('ddg'), initUrl: 'https://duckduckgo.com/', name: 'DuckDuckGo')
        ..containerColor = 1;
      await _pump(tester,
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
        values: _values(searchDefault: SiteId('kagi')),
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
      expect(seen!.searchDefault, const FollowApp<String>());
      expect(searchDefaultSays('App default'), findsOneWidget);
    });
  });
}
