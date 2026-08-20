import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_privacy.dart';

SitePrivacyValues _values({
  bool trackingProtection = false,
  bool clearUrl = false,
  bool dnsBlock = false,
  bool contentBlock = false,
  bool localCdn = false,
  bool thirdPartyCookies = false,
  bool letterbox = false,
  bool incognito = false,
  bool htmlCaching = false,
}) =>
    SitePrivacyValues(
      trackingProtectionEnabled: trackingProtection,
      clearUrlEnabled: clearUrl,
      dnsBlockEnabled: dnsBlock,
      contentBlockEnabled: contentBlock,
      localCdnEnabled: localCdn,
      thirdPartyCookiesEnabled: thirdPartyCookies,
      letterboxEnabled: letterbox,
      incognito: incognito,
      htmlCachingEnabled: htmlCaching,
    );

Future<void> _pump(
  WidgetTester tester, {
  required SitePrivacyValues values,
  ValueChanged<SitePrivacyValues>? onChanged,
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
    home: SitePrivacyScreen(
      host: 'example.com',
      siteId: 'site-1',
      values: values,
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
  group('SitePrivacyValues', () {
    test('the umbrella forces the four list-based subordinates on', () {
      const v = SitePrivacyValues(
        trackingProtectionEnabled: true,
        clearUrlEnabled: false,
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        localCdnEnabled: false,
        thirdPartyCookiesEnabled: false,
        letterboxEnabled: false,
        incognito: false,
        htmlCachingEnabled: false,
      );
      expect(v.effectiveClearUrl, isTrue);
      expect(v.effectiveDnsBlock, isTrue);
      expect(v.effectiveContentBlock, isTrue);
      expect(v.effectiveLocalCdn, isTrue);
    });

    test('the umbrella forces third-party cookies off (ETP-024)', () {
      const stored = SitePrivacyValues(
        trackingProtectionEnabled: false,
        clearUrlEnabled: false,
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        localCdnEnabled: false,
        thirdPartyCookiesEnabled: true,
        letterboxEnabled: false,
        incognito: false,
        htmlCachingEnabled: false,
      );
      expect(stored.effectiveThirdPartyCookies, isTrue);
      expect(
        stored.copyWith(trackingProtectionEnabled: true)
            .effectiveThirdPartyCookies,
        isFalse,
      );
      // The stored value survives, so turning the umbrella back off restores
      // the user's own choice rather than silently resetting it.
      expect(
        stored
            .copyWith(trackingProtectionEnabled: true)
            .copyWith(trackingProtectionEnabled: false)
            .effectiveThirdPartyCookies,
        isTrue,
      );
    });
  });

  testWidgets('third-party cookies read as forced off under the umbrella',
      (tester) async {
    await _pump(
      tester,
      values: _values(trackingProtection: true, thirdPartyCookies: true),
    );
    final tile = _switchTitled(tester, 'Third-party cookies');
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    expect(find.text('Forced off by Tracking Protection'), findsOneWidget);
  });

  testWidgets('the four list blockers read as forced on under the umbrella',
      (tester) async {
    await _pump(tester, values: _values(trackingProtection: true));
    for (final title in const ['ClearURLs', 'DNS Blocklist']) {
      final tile = _switchTitled(tester, title);
      expect(tile.value, isTrue, reason: title);
      expect(tile.onChanged, isNull, reason: title);
    }
  });

  testWidgets('every subordinate is interactive with the umbrella off',
      (tester) async {
    await _pump(tester, values: _values());
    for (final title in const [
      'ClearURLs',
      'DNS Blocklist',
      'Third-party cookies',
    ]) {
      expect(_switchTitled(tester, title).onChanged, isNotNull, reason: title);
    }
  });

  testWidgets('letterbox needs the umbrella; incognito does not',
      (tester) async {
    // Incognito destroys the user's own session on every restart, so unlike
    // the blockers it is grouped here without being forced.
    await _pump(tester, values: _values(incognito: true));
    expect(_switchTitled(tester, 'Letterbox window').onChanged, isNull);
    expect(find.text('Requires Tracking Protection'), findsOneWidget);

    final incognito = _switchTitled(tester, 'Incognito mode');
    expect(incognito.value, isTrue);
    expect(incognito.onChanged, isNotNull);
  });

  testWidgets('toggling a row reports the whole value back', (tester) async {
    SitePrivacyValues? seen;
    await _pump(
      tester,
      values: _values(incognito: true),
      onChanged: (v) => seen = v,
    );
    await tester.tap(find.text('HTML caching'));
    await tester.pumpAndSettle();
    expect(seen, isNotNull);
    expect(seen!.htmlCachingEnabled, isTrue);
    // Unrelated fields ride along untouched: the caller applies one value.
    expect(seen!.incognito, isTrue);
  });
}
