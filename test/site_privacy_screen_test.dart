import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/screens/site_privacy.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/widgets/level_slider.dart';

SitePrivacyValues _values({
  bool archived = false,
  bool trackingProtection = false,
  bool clearUrl = false,
  bool dnsBlock = false,
  int? dnsBlockLevel,
  bool contentBlock = false,
  bool localCdn = false,
  bool thirdPartyCookies = false,
  Scoped<bool> lockdownMode = const FollowApp(),
  bool letterbox = false,
  bool incognito = false,
  bool blockScreenshots = false,
}) =>
    SitePrivacyValues(
      archived: archived,
      trackingProtectionEnabled: trackingProtection,
      clearUrlEnabled: clearUrl,
      dnsBlockEnabled: dnsBlock,
      dnsBlockLevel: Scoped.fromStored(dnsBlockLevel),
      contentBlockEnabled: contentBlock,
      localCdnEnabled: localCdn,
      thirdPartyCookiesEnabled: thirdPartyCookies,
      lockdownMode: lockdownMode,
      letterboxEnabled: letterbox,
      incognito: incognito,
      blockScreenshots: blockScreenshots,
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
      siteId: SiteId('site-1'),
      values: values,
      onChanged: onChanged ?? (_) {},
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

void main() {
  group('SitePrivacyValues', () {
    test('the umbrella forces the four list-based subordinates on', () {
      const v = SitePrivacyValues(
        archived: false,
        trackingProtectionEnabled: true,
        clearUrlEnabled: false,
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        localCdnEnabled: false,
        thirdPartyCookiesEnabled: false,
        lockdownMode: const FollowApp(),
        letterboxEnabled: false,
        incognito: false,
      );
      expect(v.effectiveClearUrl, isTrue);
      expect(v.effectiveDnsBlock, isTrue);
      expect(v.effectiveContentBlock, isTrue);
      expect(v.effectiveLocalCdn, isTrue);
    });

    test('the umbrella forces third-party cookies off (ETP-024)', () {
      const stored = SitePrivacyValues(
        archived: false,
        trackingProtectionEnabled: false,
        clearUrlEnabled: false,
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        localCdnEnabled: false,
        thirdPartyCookiesEnabled: true,
        lockdownMode: const FollowApp(),
        letterboxEnabled: false,
        incognito: false,
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

  group('Lockdown Mode follows Tracking Protection (ETP-032)', () {
    tearDown(() => debugHostHasLockdownMode = null);

    Finder tile() => find.ancestor(
        of: find.text('Lockdown Mode'), matching: find.byType(ListTile));
    Finder toggle() =>
        find.descendant(of: tile(), matching: find.byType(Switch));
    double opacity(WidgetTester tester) => tester.widget<Opacity>(
        find.ancestor(of: toggle(), matching: find.byType(Opacity)).first)
        .opacity;

    test('a following site runs it exactly when the umbrella is on', () {
      final following = _values();
      expect(following.effectiveLockdownMode, isFalse);
      expect(following.copyWith(trackingProtectionEnabled: true)
          .effectiveLockdownMode, isTrue);
      final own = _values(trackingProtection: true, lockdownMode: const Own(false));
      expect(own.effectiveLockdownMode, isFalse,
          reason: 'the site may leave it under the umbrella');
    });

    testWidgets('absent where WebKit has no per-site Lockdown Mode',
        (tester) async {
      debugHostHasLockdownMode = false;
      await _pump(tester, values: _values(lockdownMode: const Own(true)));
      expect(find.text('Lockdown Mode'), findsNothing);
      expect(find.text('Security'), findsNothing);
    });

    testWidgets('under the umbrella it shows on, dimmed and not locked',
        (tester) async {
      debugHostHasLockdownMode = true;
      await _pump(tester, values: _values(trackingProtection: true));
      expect(tester.widget<Switch>(toggle()).value, isTrue);
      expect(tester.widget<Switch>(toggle()).onChanged, isNotNull);
      expect(opacity(tester), lessThan(1));
      expect(find.descendant(of: tile(),
          matching: find.text('Follows Tracking Protection')), findsOneWidget);
    });

    testWidgets('a tap leaves it for the site, a long press keeps what it shows',
        (tester) async {
      debugHostHasLockdownMode = true;
      SitePrivacyValues? seen;
      await _pump(tester,
          values: _values(trackingProtection: true),
          onChanged: (v) => seen = v);
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(seen!.lockdownMode, const Own(false));
      expect(seen!.effectiveLockdownMode, isFalse);
      expect(opacity(tester), 1);
      await tester.longPress(toggle());
      await tester.pumpAndSettle();
      expect(seen!.lockdownMode, const FollowApp<bool>());
      expect(tester.widget<Switch>(toggle()).value, isTrue);
      await tester.longPress(toggle());
      await tester.pumpAndSettle();
      expect(seen!.lockdownMode, const Own(true));
      expect(seen!.copyWith(trackingProtectionEnabled: false)
          .effectiveLockdownMode, isTrue,
          reason: 'a kept value no longer follows the umbrella');
    });
  });

  group('Block screenshots (SCREENBLOCK-003)', () {
    tearDown(() {
      ScreenCaptureGuard.debugSupportedOverride = null;
      AppPref.blockScreenshots.debugValue = false;
    });

    testWidgets('absent where the platform cannot block capture (SCREENBLOCK-001)',
        (tester) async {
      ScreenCaptureGuard.debugSupportedOverride = false;
      await _pump(tester, values: _values(blockScreenshots: true));
      expect(find.text('Block screenshots'), findsNothing);
    });

    testWidgets('switching it on reports the site value', (tester) async {
      ScreenCaptureGuard.debugSupportedOverride = true;
      SitePrivacyValues? reported;
      await _pump(tester,
          values: _values(), onChanged: (v) => reported = v);
      final tile = _switchTitled(tester, title: 'Block screenshots');
      expect(tile.value, isFalse);
      tile.onChanged!(true);
      expect(reported?.blockScreenshots, isTrue);
    });

    testWidgets('locked on while the app-wide switch covers every site',
        (tester) async {
      ScreenCaptureGuard.debugSupportedOverride = true;
      AppPref.blockScreenshots.debugValue = true;
      await _pump(tester, values: _values());
      final tile = _switchTitled(tester, title: 'Block screenshots');
      expect(tile.value, isTrue);
      expect(tile.onChanged, isNull);
      expect(find.text('On for the whole app in App Settings'), findsOneWidget);
    });
  });

  testWidgets('third-party cookies read as forced off under the umbrella',
      (tester) async {
    await _pump(
      tester,
      values: _values(trackingProtection: true, thirdPartyCookies: true),
    );
    final tile = _switchTitled(tester, title: 'Third-party cookies');
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    expect(find.text('Forced off by Tracking Protection'), findsOneWidget);
  });

  testWidgets('the four list blockers read as forced on under the umbrella',
      (tester) async {
    await _pump(tester, values: _values(trackingProtection: true));
    for (final title in const ['ClearURLs', 'DNS Blocklist']) {
      final tile = _switchTitled(tester, title: title);
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
      expect(_switchTitled(tester, title: title).onChanged, isNotNull,
          reason: title);
    }
  });

  testWidgets('letterbox needs the umbrella; incognito does not',
      (tester) async {
    // Incognito destroys the user's own session on every restart, so unlike
    // the blockers it leads the screen without being forced.
    await _pump(tester, values: _values(incognito: true));
    expect(_switchTitled(tester, title: 'Letterbox window').onChanged, isNull);
    expect(find.text('Requires Tracking Protection'), findsOneWidget);

    final incognito = _switchTitled(tester, title: 'Incognito mode');
    expect(incognito.value, isTrue);
    expect(incognito.onChanged, isNotNull);
  });

  testWidgets('the umbrella states its forcing once, not on every row',
      (tester) async {
    // Four greyed-on switches each captioned "Forced on by Tracking
    // Protection" buried the one thing those subtitles carry, which is
    // whether the blocker has data. Taking third-party cookies away is the
    // counterintuitive direction, so that row keeps its note.
    await _pump(
      tester,
      values: _values(trackingProtection: true, thirdPartyCookies: true),
    );
    expect(find.textContaining('Forced on by'), findsNothing);
    expect(find.text('Forced off by Tracking Protection'), findsOneWidget);
    expect(find.text('Strip tracking parameters from URLs'), findsOneWidget);
  });

  group('the per-site level uses the same slider as App Settings', () {
    // The level row only renders with a blocklist in memory, and the slider's
    // stops are the levels the app knows about, so the service has to be
    // seeded rather than stubbed at the call site.
    setUp(() {
      DnsBlockService.instance.loadLevelsFromStrings(
        {2: 'normal.example', 3: 'pro.example'},
        globalLevel: 3,
      );
    });
    tearDown(DnsBlockService.instance.resetForTest);

    LevelSlider slider(WidgetTester tester) {
      final found = find.byType(LevelSlider);
      expect(found, findsOneWidget);
      return tester.widget<LevelSlider>(found);
    }

    testWidgets('the leftmost stop is the app-wide setting', (tester) async {
      await _pump(tester, values: _values(dnsBlock: true));
      final s = slider(tester);
      expect(s.value, 0);
      expect(s.labels, ['App', 'Light', 'Normal', 'Pro', 'Pro++', 'Ultimate']);
      expect(find.text('Same as app settings (Pro)'), findsOneWidget);
    });

    testWidgets('a site level puts the thumb on that level', (tester) async {
      await _pump(tester, values: _values(dnsBlock: true, dnsBlockLevel: 2));
      expect(slider(tester).value, 2);
    });

    testWidgets('moving the thumb reports the level, stop 0 reports null',
        (tester) async {
      SitePrivacyValues? seen;
      await _pump(
        tester,
        values: _values(dnsBlock: true, dnsBlockLevel: 2),
        onChanged: (v) => seen = v,
      );
      slider(tester).onChanged!(3);
      expect(seen!.dnsBlockLevel, const Own(3));
      await tester.pumpAndSettle();
      slider(tester).onChanged!(0);
      expect(seen!.dnsBlockLevel, const FollowApp<int>());
      expect(seen!.dnsBlockLevel.stored, isNull);
    });
  });

  group('HTTPS upgrade follows App Settings until overridden (HTTPS-005)', () {
    tearDown(() => AppPref.httpsUpgradeEnabled.debugValue = true);

    Finder tile() => find.ancestor(
        of: find.text('HTTPS upgrade'), matching: find.byType(ListTile));
    Finder toggle() =>
        find.descendant(of: tile(), matching: find.byType(Switch));
    bool shown(WidgetTester tester) => tester.widget<Switch>(toggle()).value;
    double opacity(WidgetTester tester) => tester.widget<Opacity>(
        find.ancestor(of: toggle(), matching: find.byType(Opacity)).first)
        .opacity;

    testWidgets('a site follows the app dimmed until it makes its own choice',
        (tester) async {
      SitePrivacyValues? seen;
      await _pump(tester, values: _values(), onChanged: (v) => seen = v);
      expect(shown(tester), isTrue, reason: 'the app default is on');
      expect(opacity(tester), lessThan(1));
      expect(find.descendant(of: tile(), matching: find.text('App default')),
          findsOneWidget);

      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(seen!.httpsUpgrade, const Own(false));
      expect(shown(tester), isFalse);
      expect(opacity(tester), 1);

      await tester.longPress(toggle());
      await tester.pumpAndSettle();
      expect(seen!.httpsUpgrade, const FollowApp<bool>());
      expect(seen!.httpsUpgrade.stored, isNull, reason: 'stored as null');
      AppPref.httpsUpgradeEnabled.debugValue = false;
      await tester.pumpAndSettle();
      expect(shown(tester), isFalse, reason: "a following site shows the app's");
    });

    testWidgets('Tracking Protection shows it forced on and locks it',
        (tester) async {
      await _pump(tester,
          values: _values(trackingProtection: true)
              .copyWith(httpsUpgrade: const Own(false)));
      expect(shown(tester), isTrue);
      expect(opacity(tester), 1, reason: 'the value is forced, not followed');
      expect(tester.widget<Switch>(toggle()).onChanged, isNull);
      expect(tester.widget<ListTile>(tile()).enabled, isFalse);
    });
  });

  testWidgets('an archived site shows the posture the archive holds it to',
      (tester) async {
    await _pump(tester, values: _values(archived: true));
    final incognito = _switchTitled(tester, title: 'Incognito mode');
    expect(incognito.value, isTrue, reason: 'ARCH-006: always incognito');
    expect(incognito.onChanged, isNull);
    expect(find.text('Fixed for sites in an archive'), findsOneWidget);
  });

  testWidgets('toggling a row reports the whole value back', (tester) async {
    SitePrivacyValues? seen;
    await _pump(
      tester,
      values: _values(incognito: true, clearUrl: true),
      onChanged: (v) => seen = v,
    );
    await tester.tap(find.text('ClearURLs'));
    await tester.pumpAndSettle();
    expect(seen, isNotNull);
    expect(seen!.clearUrlEnabled, isFalse);
    // Unrelated fields ride along untouched: the caller applies one value.
    expect(seen!.incognito, isTrue);
  });
}
