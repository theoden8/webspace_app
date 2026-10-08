// App settings' Developer screen and the Tor rows it no longer carries.
//
// Tor graduated out of the Experimental group (TOR-007): developer mode does
// not hold it, so turning developer mode off costs a Tor site nothing and asks
// nothing. The status card under the proxy block reports a runtime something
// uses, so it stays out of the list until something does (TOR-004).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/main.dart' show AppThemeSettings;
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/tor_status.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/tor_status_card.dart';
import 'helpers/fake_tor_runtime.dart';

final Uint8List _png64 =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));

void main() {
  Widget host({
    bool routerRunsHere = false,
    Map<String, String> siteNames = const {},
    List<({String siteId, String name, int? containerColor})> webSearchSites =
        const [],
  }) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSettingsScreen(
          currentSettings: AppThemeSettings(),
          proxyRouterRunsHere: routerRunsHere,
          siteNames: siteNames,
          onSettingsChanged: (_) {},
          onExportSettings: () {},
          onImportSettings: () {},
          onOpenLinkHandlingSettings: () {},
          webSearchSites: webSearchSites,
        ),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
    // The Developer row is only listed once the flag is on.
    DeveloperModeService.instance.debugSet(on: true);
  });

  /// Opens one App Settings category through its row on the index.
Future<void> openCategory(WidgetTester tester, {required String title}) async {
  final row = find.text(title);
  await tester.scrollUntilVisible(row, 200,
      scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

  tearDown(() async {
    DeveloperModeService.instance.debugSet(on: false);
    for (final f in ExperimentalFeature.values) {
      ExperimentalFeaturesService.instance.debugSet(f, on: f.pref.fallback);
    }
    await TorService.reset();
  });

  /// The developer-mode switch on the Developer screen. Found through its
  /// title rather than by position: it is not the only `SwitchListTile` on
  /// the screen, and which one is last changes as rows are added.
  Future<Finder> developerModeSwitch(WidgetTester tester) async {
    await openCategory(tester, title: 'Developer');
    final title = find.text('Developer mode');
    await tester.scrollUntilVisible(title, 400,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    return find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
  }

  testWidgets('developer mode turns off without a word, whatever uses Tor',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(await developerModeSwitch(tester));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing,
        reason: 'developer mode no longer holds Tor, so turning it off '
            'blocks nothing');
    expect(DeveloperModeService.instance.enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.developerMode.key), isFalse,
        reason: 'the flag must survive a restart');
    expect(find.text('Experimental'), findsNothing,
        reason: 'the Developer screen closes with developer mode');
    expect(find.text('App Logs'), findsOneWidget,
        reason: 'App Settings links the logs directly again');
  });

  group('Tor in App settings (TOR-004, TOR-007)', () {
    late FakeTorRuntime runtime;

    setUp(() {
      runtime = FakeTorRuntime();
      TorService.overrideEngine(
          TorEngine(runtime: runtime, sessionSecret: 's'));
      DeveloperModeService.instance.debugSet(on: false);
    });

    /// Opens the Network screen, where the outbound proxy block and the
    /// card under it fit without scrolling.
    Future<void> scrollToCard(WidgetTester tester) =>
        openCategory(tester, title: 'Network');

    testWidgets('TOR is offered app-wide with developer mode off',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(TorService.instance.isAvailable, isTrue);
      await scrollToCard(tester);
      final dropdown = tester.widget<DropdownButton<String>>(find.descendant(
          of: find.byType(ProxyChoiceDropdown),
          matching: find.byType(DropdownButton<String>)));
      expect(dropdown.items!.map((i) => i.value), contains(ProxyType.TOR.name));
    });

    testWidgets('no card while nothing uses Tor', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await scrollToCard(tester);
      expect(find.byType(TorStatusCard), findsOneWidget);
      expect(find.text('Not running'), findsNothing,
          reason: 'a stopped runtime has nothing to act on');
      expect(find.text('Tor'), findsNothing);
    });

    testWidgets('the card appears once something starts Tor', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await TorService.instance.maybeStart(TorSiteHolder('site-a'));
      runtime.emit(const TorUp('127.0.0.1', port: 41337));
      await tester.pumpAndSettle();
      await scrollToCard(tester);
      expect(find.text('Tor'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('tapping the card opens what Tor is doing app-wide',
        (tester) async {
      await tester.pumpWidget(host(siteNames: const {'site-a': 'Mail'}));
      await tester.pumpAndSettle();
      await TorService.instance.syncHolders({TorSiteHolder('site-a')});
      runtime.emit(const TorUp('127.0.0.1', port: 41337));
      await tester.pumpAndSettle();
      await scrollToCard(tester);

      await tester.tap(find.text('Tor'));
      await tester.pumpAndSettle();
      expect(find.byType(TorStatusScreen), findsOneWidget);
      expect(find.text('Using Tor'), findsOneWidget);
      expect(find.text('Mail'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 91));
    });

    testWidgets('there is no per-destination circuit switch', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await scrollToCard(tester);
      expect(find.text('Separate circuit per destination'), findsNothing,
          reason: 'circuits are isolated per site only (TOR-003)');
    });
  });

  group('Experimental group (DEVTOOLS-011)', () {
    testWidgets('never offers Tor, even where the runtime exists',
        (tester) async {
      TorService.overrideEngine(
          TorEngine(runtime: FakeTorRuntime(), sessionSecret: 's'));
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Developer');
      final header = find.text('Experimental');
      await tester.scrollUntilVisible(header, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(header, findsOneWidget,
          reason: 'site tabs run on every platform, so the group always has '
              'a row');
      expect(find.text('Built-in Tor'), findsNothing,
          reason: 'Tor is not experimental');
      expect(find.text('Link routing between sites'), findsNothing,
          reason: 'link routing is no longer experimental');
    });

    testWidgets('Saved proxies have a row, not a switch (PROXY-030)',
        (tester) async {
      Finder savedProxies(Type tile) => find.ancestor(
          of: find.text('Saved proxies'), matching: find.byType(tile));

      DeveloperModeService.instance.debugSet(on: false);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Network');
      await tester.scrollUntilVisible(find.text('Saved proxies'), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(savedProxies(ListTile), findsOneWidget,
          reason: 'the library is offered with developer mode off');

      DeveloperModeService.instance.debugSet(on: true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Developer');
      await tester.scrollUntilVisible(find.text('Experimental'), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(savedProxies(SwitchListTile), findsNothing,
          reason: 'saved proxies are not experimental');
    });

    testWidgets(
        'Default search tells same-named sites apart by id and colour '
        '(LIR-029, TAB-018)', (tester) async {
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.siteTabs, on: true);
      await tester.pumpWidget(host(webSearchSites: [
        (siteId: 'ddg-work', name: 'DuckDuckGo', containerColor: 2),
        (siteId: 'ddg-home', name: 'DuckDuckGo', containerColor: 5),
      ]));
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Behaviour');
      final row = find.text('Default search');
      await tester.scrollUntilVisible(row, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(RadioListTile<String>, 'DuckDuckGo'),
          findsNWidgets(2));
      expect(find.text('ddg-work'), findsOneWidget);
      expect(find.text('ddg-home'), findsOneWidget);
      Color dotOf(String id) {
        final line = find.ancestor(
            of: find.text(id), matching: find.byType(SiteIdLine));
        final box = tester.widget<Container>(find.descendant(
            of: line, matching: find.byType(Container)));
        return (box.decoration! as BoxDecoration).color!;
      }

      expect(dotOf('ddg-work'),
          ContainerColors.of(2, brightness: Brightness.light));
      expect(dotOf('ddg-home'),
          ContainerColors.of(5, brightness: Brightness.light));

      await tester.tap(find.text('ddg-home'));
      await tester.pumpAndSettle();
      expect(find.text('DuckDuckGo (ddg-home)'), findsOneWidget,
          reason: 'the row names which DuckDuckGo it is');
    });

    testWidgets('the site search list waits for the user (LIR-036)',
        (tester) async {
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.siteTabs, on: true);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Behaviour');
      final row = find.text('Site search list');
      await tester.scrollUntilVisible(row, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final tile = find.ancestor(of: row, matching: find.byType(ListTile));
      expect(
          find.descendant(of: tile, matching: find.text('Not downloaded')),
          findsOneWidget);
      expect(
          find.descendant(
              of: tile, matching: find.byTooltip('Download dataset')),
          findsOneWidget,
          reason: 'nothing is fetched until the user asks');
    });

    testWidgets('offers Site tabs everywhere, off by default (TAB-012)',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Developer');
      final title = find.text('Site tabs');
      await tester.scrollUntilVisible(title, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final tile =
          find.ancestor(of: title, matching: find.byType(SwitchListTile));
      expect(tester.widget<SwitchListTile>(tile).value, isFalse,
          reason: 'tabs are new, so developer mode alone does not open them');
      expect(
          ExperimentalFeaturesService.instance
              .isEnabled(ExperimentalFeature.siteTabs),
          isFalse);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(
          ExperimentalFeaturesService.instance
              .isEnabled(ExperimentalFeature.siteTabs),
          isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppPref.experimentalSiteTabs.key), isTrue);

      DeveloperModeService.instance.debugSet(on: false);
      expect(
          ExperimentalFeaturesService.instance
              .isEnabled(ExperimentalFeature.siteTabs),
          isFalse,
          reason: 'the switch narrows developer mode, never widens it');
    });

    testWidgets('offers the Proxy router where it could run, on by default',
        (tester) async {
      await tester.pumpWidget(host(routerRunsHere: true));
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Developer');
      final title = find.text('Proxy router');
      await tester.scrollUntilVisible(title, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      // The row is scrolled to the top, so its header sits under the app bar.
      expect(find.text('Experimental', skipOffstage: false), findsOneWidget);

      final tile =
          find.ancestor(of: title, matching: find.byType(SwitchListTile));
      expect(tester.widget<SwitchListTile>(tile).value, isTrue,
          reason: 'developer mode alone ran the router before the switch');
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing,
          reason: 'turning it off only brings back PROXY-008 at next launch');
      expect(
          ExperimentalFeaturesService.instance
              .switchOn(ExperimentalFeature.proxyRouter),
          isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppPref.experimentalProxyRouter.key), isFalse);
    });

    testWidgets('offers Site icons only on every platform, off by default',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Developer');
      final title = find.text('Site icons only');
      await tester.scrollUntilVisible(title, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      final tile =
          find.ancestor(of: title, matching: find.byType(SwitchListTile));
      expect(tester.widget<SwitchListTile>(tile).value, isFalse,
          reason: 'a new experiment starts off');
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(
          ExperimentalFeaturesService.instance
              .isEnabled(ExperimentalFeature.siteIconsOnly),
          isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppPref.experimentalSiteIconsOnly.key), isTrue);
    });

    testWidgets('Reset icon cache forgets every cached icon', (tester) async {
      SharedPreferences.setMockInitialValues({
        'favicon_url_https://a.test/': 'https://a.test/icon.png',
        'favicon_svg_https://a.test/icon.svg': '<svg/>',
        'favicon_url_https://b.test/':
            'https://www.google.com/s2/favicons?domain=b.test&sz=256',
        AppPref.experimentalProxyRouter.key: true,
      });
      await FaviconUrlCache.initialize();
      final files = MemoryFileStore();
      final previous = SiteIconStore.instance;
      addTearDown(() => SiteIconStore.instance = previous);
      SiteIconStore.instance = SiteIconStore(store: files);
      await SiteIconStore.instance.initialize();
      await SiteIconStore.instance.offer(
          'https://a.test/', icon: SiteIcon(_png64, width: 64, height: 64),
          persist: true);

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await openCategory(tester, title: 'Developer');
      final row = find.text('Reset icon cache');
      await tester.scrollUntilVisible(row, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('favicon_')), isEmpty);
      expect(prefs.getBool(AppPref.experimentalProxyRouter.key), isTrue,
          reason: 'only icon entries go');
      expect(SiteIconStore.instance.get('https://a.test/'), isNull);
      expect(await files.list(), isEmpty);
      expect(find.text('Icon cache cleared'), findsOneWidget);
    });
  });

  // The hint is the only place the auto-update explanation is reachable, so
  // it has to carry both halves (DM-004).
  testWidgets('the Firefox version hint explains manual and automatic updates',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await openCategory(tester, title: 'Privacy');
    final row = find.ancestor(
        of: find.text('Firefox version'), matching: find.byType(ListTile));
    await tester.scrollUntilVisible(find.text('Firefox version'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.info_outline)));
    await tester.pumpAndSettle();

    final loc = AppLocalizations.of(tester.element(row));
    final dialog = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join('\n');
    expect(dialog, contains(loc.appSettingsFirefoxVersionHint));
    expect(dialog, contains(loc.appSettingsFirefoxAutoUpdateHint));
  });
}
