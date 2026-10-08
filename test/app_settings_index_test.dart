// App Settings is an index of categories (APPSET-001): each row opens a
// screen of its own and says what that category is set to (APPSET-002).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/settings/app_prefs.dart';

void main() {
  setUp(() async {
    // Off where the default is on, so each test turns on what it names.
    SharedPreferences.setMockInitialValues({
      AppPref.fullscreenOnShortcut.key: false,
      AppPref.linkHandlingEnabled.key: false,
      AppPref.httpsUpgradeEnabled.key: false,
    });
    AppPref.loadAll(await SharedPreferences.getInstance());
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
    DeveloperModeService.instance.debugSet(on: false);
  });

  tearDown(() => DeveloperModeService.instance.debugSet(on: false));

  Widget settings({VoidCallback? onExportSettings}) => AppSettingsScreen(
        currentSettings: AppThemeSettings(),
        onSettingsChanged: (_) {},
        onExportSettings: onExportSettings ?? () {},
        onImportSettings: () {},
        onOpenLinkHandlingSettings: () {},
      );

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      );

  Finder summaryOf(String title) => find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
        matching: find.byWidgetPredicate(
            (w) => w is Text && w.data != title && w.style?.fontSize == 12.5),
      );

  String summaryText(WidgetTester tester, {required String title}) =>
      tester.widget<Text>(summaryOf(title)).data!;

  /// Brings a row fully on screen and opens it.
  Future<void> openRow(WidgetTester tester, {required String title}) async {
    final row = find.text(title);
    await tester.scrollUntilVisible(row, 100,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  testWidgets('the index lists the categories in order and no setting',
      (tester) async {
    // Tall enough that the ListView builds every row, so their positions
    // can be compared directly.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(settings()));
    await tester.pumpAndSettle();

    final titles = [
      'Appearance',
      'Behaviour',
      'Network',
      'Privacy',
      'User Scripts',
      'Backup and archives',
      'App Logs',
      'Licenses',
      'Version',
    ];
    final tops = [
      for (final title in titles) tester.getTopLeft(find.text(title)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()),
        reason: 'the categories keep their order: $titles');

    expect(find.byType(SwitchListTile, skipOffstage: false), findsNothing);
    expect(find.byType(SegmentedButton<TabStrip>, skipOffstage: false),
        findsNothing);
    expect(find.byType(Slider, skipOffstage: false), findsNothing);
    expect(find.byType(TextField, skipOffstage: false), findsNothing);
    expect(find.text('Developer'), findsNothing,
        reason: 'the Developer row exists only in developer mode');
  });

  testWidgets('Appearance names the theme and a chosen language',
      (tester) async {
    await tester.pumpWidget(app(settings()));
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Appearance'), 'System');

    AppPref.appLocaleOverride.debugValue = 'de';
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Appearance'), 'System · Deutsch',
        reason: 'the row follows the pref as it changes');
  });

  testWidgets('Behaviour names what is on, two then a count', (tester) async {
    await tester.pumpWidget(app(settings()));
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Behaviour'), 'Nothing enabled');

    AppPref.showTabStrip.debugValue = true;
    AppPref.fullscreenOnShortcut.debugValue = true;
    AppPref.linkHandlingEnabled.debugValue = true;
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Behaviour'),
        'Site Tab Strip · Full screen on shortcut launch · 1 more');
  });

  testWidgets('a change on a category screen reaches the app and the row',
      (tester) async {
    await tester.pumpWidget(app(settings()));
    await tester.pumpAndSettle();

    await openRow(tester, title: 'Behaviour');
    await tester.tap(find.ancestor(
        of: find.text('Full screen on shortcut launch'),
        matching: find.byType(SwitchListTile)));
    await tester.pumpAndSettle();
    expect(AppPref.fullscreenOnShortcut.value, isTrue,
        reason: 'applied at once, as before');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Behaviour'),
        'Full screen on shortcut launch');
  });

  testWidgets('Network and Privacy say what every site gets', (tester) async {
    AppPref.httpsUpgradeEnabled.debugValue = true;
    await tester.pumpWidget(app(settings()));
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Network'), 'Default connection');
    expect(DnsBlockService.instance.level, 0);
    expect(summaryText(tester, title: 'Privacy'), 'HTTPS upgrade');

    AppPref.httpsUpgradeEnabled.debugValue = false;
    await tester.pumpAndSettle();
    expect(summaryText(tester, title: 'Privacy'), 'No protection enabled');
  });

  testWidgets('Export closes settings before it runs, as it did inline',
      (tester) async {
    var exported = false;
    await tester.pumpWidget(app(Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => settings(onExportSettings: () => exported = true),
          ),
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await openRow(tester, title: 'Backup and archives');
    await tester.tap(find.text('Export Settings'));
    await tester.pumpAndSettle();

    expect(exported, isTrue);
    expect(find.byType(AppSettingsScreen), findsNothing,
        reason: 'the main page runs the export, with settings closed');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('developer mode trades App Logs for a Developer row',
      (tester) async {
    DeveloperModeService.instance.debugSet(on: true);
    await tester.pumpWidget(app(settings()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Developer'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('App Logs'), findsNothing,
        reason: 'the logs are on the Developer screen');

    await openRow(tester, title: 'Developer');
    expect(find.text('App Logs'), findsOneWidget);
    expect(find.text('Experimental'), findsOneWidget);
  });

  // A second tap that reaches a screen before the route it opened has laid
  // out over it is how a fast double tap stacks two copies. The test binding
  // lays the new route out between two taps, so the second one is delivered
  // the way the gesture would deliver it: the row's handler again, before a
  // frame.
  group('one tap, one action (UI race conditions)', () {
    VoidCallback onTapOf(WidgetTester tester, {required String title}) => tester
        .widget<ListTile>(
            find.ancestor(of: find.text(title), matching: find.byType(ListTile)))
        .onTap!;

    Widget launcher(Widget Function() settingsScreen) => app(Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => settingsScreen()),
            ),
            child: const Text('open'),
          ),
        ));

    testWidgets('a double tap on a category opens it once', (tester) async {
      await tester.pumpWidget(app(settings()));
      await tester.pumpAndSettle();

      final tap = onTapOf(tester, title: 'Behaviour');
      tap();
      tap();
      await tester.pumpAndSettle();
      expect(find.byType(AppBehaviourScreen, skipOffstage: false),
          findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(AppSettingsScreen), findsOneWidget,
          reason: 'one back press returns to the index');
    });

    testWidgets('a double tap on Export runs it once and stops at the page '
        'settings was opened from', (tester) async {
      var exports = 0;
      await tester.pumpWidget(launcher(
          () => settings(onExportSettings: () => exports++)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await openRow(tester, title: 'Backup and archives');

      final tap = onTapOf(tester, title: 'Export Settings');
      tap();
      tap();
      await tester.pumpAndSettle();

      expect(exports, 1);
      expect(find.byType(AppSettingsScreen), findsNothing);
      expect(find.text('open'), findsOneWidget,
          reason: 'the page under settings stays');
    });

    testWidgets('flipping developer mode off twice leaves one screen',
        (tester) async {
      DeveloperModeService.instance.debugSet(on: true);
      await tester.pumpWidget(launcher(settings));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await openRow(tester, title: 'Developer');

      final flip = tester
          .widget<SwitchListTile>(find.ancestor(
              of: find.text('Developer mode'),
              matching: find.byType(SwitchListTile)))
          .onChanged!;
      flip(false);
      flip(false);
      await tester.pumpAndSettle();

      expect(DeveloperModeService.instance.enabled, isFalse);
      expect(find.byType(AppSettingsScreen), findsOneWidget,
          reason: 'only the Developer screen closes');
      expect(find.text('App Logs'), findsOneWidget);
    });
  });
}
