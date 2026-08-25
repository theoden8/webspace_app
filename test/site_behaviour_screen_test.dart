import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_behaviour.dart';

SiteBehaviourValues _values({
  bool alwaysOpenHome = false,
  bool kioskMode = false,
  bool fullscreenMode = false,
  bool htmlCaching = false,
  bool blockAutoRedirects = true,
  bool externalLinksInBrowser = false,
}) =>
    SiteBehaviourValues(
      alwaysOpenHome: alwaysOpenHome,
      kioskMode: kioskMode,
      fullscreenMode: fullscreenMode,
      htmlCachingEnabled: htmlCaching,
      blockAutoRedirects: blockAutoRedirects,
      externalLinksInBrowser: externalLinksInBrowser,
    );

Future<void> _pump(
  WidgetTester tester, {
  required SiteBehaviourValues values,
  bool incognito = false,
  Widget? domainClaims,
  ValueChanged<SiteBehaviourValues>? onChanged,
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
}
