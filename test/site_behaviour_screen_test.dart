import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/hint_button.dart';

SiteBehaviourValues _values({
  bool alwaysOpenHome = false,
  bool kioskMode = false,
  bool fullscreenMode = false,
  bool htmlCaching = false,
  bool blockAutoRedirects = true,
  bool externalLinksInBrowser = false,
  bool routeOutboundLinks = false,
  List<OutboundPreference> outboundPreferences = const [],
}) =>
    SiteBehaviourValues(
      alwaysOpenHome: alwaysOpenHome,
      kioskMode: kioskMode,
      fullscreenMode: fullscreenMode,
      htmlCachingEnabled: htmlCaching,
      blockAutoRedirects: blockAutoRedirects,
      externalLinksInBrowser: externalLinksInBrowser,
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
  bool showOutboundRouting = true,
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
      showOutboundRouting: showOutboundRouting,
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

void main() {
  group('SiteBehaviourValues', () {
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
      'Open external links in browser',
    ]) {
      expect(_switchTitled(tester, title).onChanged, isNotNull, reason: title);
    }
    expect(find.text('Opening and display'), findsOneWidget);
    expect(find.text('Link handling'), findsOneWidget);
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
    // Below the external-links switch, whose hint points the reader at it.
    final claims = tester.getTopLeft(find.text('claims-slot')).dy;
    final external =
        tester.getTopLeft(find.text('Open external links in browser')).dy;
    expect(claims, greaterThan(external));
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

    testWidgets('the switch sits between redirects and external links',
        (tester) async {
      await _pump(tester, values: _values());
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Route links to my sites'),
          greaterThan(y('Block auto-redirects')));
      expect(y('Route links to my sites'),
          lessThan(y('Open external links in browser')));
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

    testWidgets('the experiment off hides both rows', (tester) async {
      await _pump(
        tester,
        values: _values(routeOutboundLinks: true, outboundPreferences: [pref]),
        routingTargets: [gh],
        showOutboundRouting: false,
      );
      expect(find.text('Route links to my sites'), findsNothing);
      expect(find.text('Routing preferences'), findsNothing);
      expect(_switchTitled(tester, 'Open external links in browser').onChanged,
          isNotNull);
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
