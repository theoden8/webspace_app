// Turning developer mode off shuts the TOR-007 gate, and from that moment
// every site pinned to Tor is blocked (TOR-008 keeps it blocked rather than
// sending it over the device IP). The confirm dialog is the only place that
// says so: the next reminder is a site sitting on the interstitial, which is
// how this was reported in the first place.
//
// Four things the screen has to get right, none of which the engine tests can
// see:
//   * silence when no site is pinned, so the flag stays cheap to toggle;
//   * the warning names how many sites, so the cost is legible;
//   * cancelling leaves developer mode ON and the switch where it was;
//   * the count is read when the switch is flipped, not when the screen was
//     built -- a site can be pinned to Tor from the drawer behind it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/main.dart' show AppThemeSettings;
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/developer_mode_service.dart';

void main() {
  /// Read by the screen through the callback, and mutable so a test can pin a
  /// site after the screen is built.
  var torSites = 0;

  Widget host() => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSettingsScreen(
          currentSettings: AppThemeSettings(),
          torPinnedSiteCount: () => torSites,
          onSettingsChanged: (_) {},
          onExportSettings: () {},
          onImportSettings: () {},
          showTabStrip: false,
          onShowTabStripChanged: (_) {},
          tabStripInFullscreen: false,
          onTabStripInFullscreenChanged: (_) {},
          fullscreenOnShortcut: false,
          onFullscreenOnShortcutChanged: (_) {},
          backOpensMenu: false,
          onBackOpensMenuChanged: (_) {},
          httpsUpgradeEnabled: true,
          onHttpsUpgradeEnabledChanged: (_) {},
          tabBarButton: false,
          onTabBarButtonChanged: (_) {},
          tabMaxWidth: 140,
          onTabMaxWidthChanged: (_) {},
          showStatsBanner: false,
          onShowStatsBannerChanged: (_) {},
          localeOverride: '',
          onLocaleOverrideChanged: (_) {},
          linkHandlingEnabled: true,
          onLinkHandlingEnabledChanged: (_) {},
          onOpenLinkHandlingSettings: () {},
        ),
      );

  setUp(() async {
    torSites = 0;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
    // The switch is only rendered once the flag is on, which is also the only
    // state from which it can be turned off.
    DeveloperModeService.instance.debugSet(true);
  });

  tearDown(() => DeveloperModeService.instance.debugSet(false));

  /// The developer-mode switch, scrolled into view. Found through its title
  /// rather than by position: it is not the only `SwitchListTile` on the
  /// screen, and which one is last changes as rows are added.
  Future<Finder> developerModeSwitch(WidgetTester tester) async {
    final title = find.text('Developer mode');
    await tester.scrollUntilVisible(title, 400,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    return find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
  }

  testWidgets('with no site on Tor the flag turns off without a word',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(await developerModeSwitch(tester));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing,
        reason: 'nothing is lost, so there is nothing to confirm');
    expect(DeveloperModeService.instance.enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kDeveloperModeKey), isFalse,
        reason: 'the flag must survive a restart');
  });

  testWidgets('with sites on Tor it says how many will block', (tester) async {
    torSites = 2;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(await developerModeSwitch(tester));
    await tester.pumpAndSettle();

    expect(find.text('Turn Developer mode off?'), findsOneWidget);
    expect(find.textContaining('2 sites are set to use Tor'), findsOneWidget,
        reason: 'the count is the whole point: it is what makes the cost '
            'legible before the switch moves');
    expect(DeveloperModeService.instance.enabled, isTrue,
        reason: 'nothing changes until the dialog is answered');

    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(DeveloperModeService.instance.enabled, isFalse);
  });

  testWidgets('cancelling leaves the flag on and the switch on',
      (tester) async {
    torSites = 1;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(await developerModeSwitch(tester));
    await tester.pumpAndSettle();
    expect(find.textContaining('One site is set to use Tor'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(DeveloperModeService.instance.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kDeveloperModeKey), isNot(false),
        reason: 'a cancelled toggle must not have been written');
    // The switch itself, not just the service: a cancel that left the knob
    // reading "off" would be the toggle contradicting the state it controls.
    final tile =
        tester.widget<SwitchListTile>(await developerModeSwitch(tester));
    expect(tile.value, isTrue);
  });

  testWidgets('the count is read when the switch is flipped, not at build',
      (tester) async {
    // A site can be pinned to Tor from the drawer while this screen sits open.
    // A count captured at construction would report zero here and turn the
    // flag off silently, which is the failure this callback exists to avoid.
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    torSites = 3;
    await tester.tap(await developerModeSwitch(tester));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 sites are set to use Tor'), findsOneWidget);
    expect(DeveloperModeService.instance.enabled, isTrue);
  });

  testWidgets('turning the flag back on is never gated', (tester) async {
    // The confirmation belongs to losing Tor, not to gaining it. A dialog
    // here would put a warning in front of the action that fixes it.
    torSites = 2;
    DeveloperModeService.instance.debugSet(false);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('Developer mode'), findsNothing,
        reason: 'the switch is not rendered while the flag is off, so the '
            'only way back on is the version-row gesture');
  });
}
