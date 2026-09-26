import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/hint_button.dart';

SiteBehaviourValues _values({
  bool alwaysOpenHome = false,
  bool kioskMode = false,
  bool fullscreenMode = false,
  bool htmlCaching = false,
  bool blockAutoRedirects = true,
  ExternalLinkMode externalLinkMode = ExternalLinkMode.inApp,
  bool routeOutboundLinks = false,
  List<OutboundPreference> outboundPreferences = const [],
}) =>
    SiteBehaviourValues(
      alwaysOpenHome: alwaysOpenHome,
      kioskMode: kioskMode,
      fullscreenMode: fullscreenMode,
      htmlCachingEnabled: htmlCaching,
      blockAutoRedirects: blockAutoRedirects,
      externalLinkMode: externalLinkMode,
      routeOutboundLinks: routeOutboundLinks,
      outboundPreferences: outboundPreferences,
    );

Future<void> _pump(
  WidgetTester tester, {
  required SiteBehaviourValues values,
  bool incognito = false,
  Widget? domainClaims,
  ValueChanged<SiteBehaviourValues>? onChanged,
  bool containersActive = true,
  List<WebViewModel> routingTargets = const [],
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

RadioListTile<ExternalLinkMode> _radioTitled(WidgetTester tester, String title) {
  final tile = find.ancestor(
    of: find.text(title),
    matching: find.byType(RadioListTile<ExternalLinkMode>),
  );
  expect(tile, findsOneWidget, reason: 'no option titled "$title"');
  return tester.widget<RadioListTile<ExternalLinkMode>>(tile);
}

ExternalLinkMode? _selectedMode(WidgetTester tester) => tester
    .widget<RadioGroup<ExternalLinkMode>>(
        find.byType(RadioGroup<ExternalLinkMode>))
    .groupValue;

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
      'Block auto-redirects',
      'Route links to my sites',
    ]) {
      expect(_switchTitled(tester, title).onChanged, isNotNull, reason: title);
    }
    expect(find.text('Opening and display'), findsOneWidget);
    expect(find.text('Link handling'), findsOneWidget);
    expect(find.text('Open external links in browser'), findsNothing,
        reason: 'the switch became the browser option of External links');
  });

  group('external links (BEHAV-004)', () {
    testWidgets('one choice of three, explained behind its hint',
        (tester) async {
      await _pump(tester, values: _values());
      for (final option in const ['Open in the app', 'Open in browser', 'Block']) {
        _radioTitled(tester, option);
      }
      expect(_selectedMode(tester), ExternalLinkMode.inApp);
      final header = find.ancestor(
        of: find.text('External links'),
        matching: find.byType(ListTile),
      );
      final hint = tester.widget<HintButton>(
          find.descendant(of: header, matching: find.byType(HintButton)));
      expect(hint.title, 'External links');
      expect(tester.widget<ListTile>(header).subtitle, isNull);
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
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
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
    expect(seen!.blockAutoRedirects, isTrue);
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
    final lastOption = tester.getTopLeft(find.text('Block')).dy;
    expect(claims, greaterThan(lastOption));
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
      expect(y('Route links to my sites'), greaterThan(y('Open in the app')));
      expect(y('Route links to my sites'), lessThan(y('Open in browser')));
      expect(x('Route links to my sites'), x('Open in the app'),
          reason: 'indented under the option it belongs to');
      expect(x('Route links to my sites'),
          greaterThan(x('Block auto-redirects')));
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
      await tester.tap(find.text('Open in browser'));
      await tester.pumpAndSettle();
      expect(find.text('Route links to my sites'), findsNothing);
      expect(seen!.routeOutboundLinks, isTrue);
      await tester.tap(find.text('Open in the app'));
      await tester.pumpAndSettle();
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
}
