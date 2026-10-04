// App settings' Developer section and the Tor rows it no longer carries.
//
// Tor graduated out of the Experimental group (TOR-007): developer mode does
// not hold it, so turning developer mode off costs a Tor site nothing and asks
// nothing. The status card under the proxy block reports a runtime something
// uses, so it stays out of the list until something does (TOR-004).

import 'dart:async';
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
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/tor_status_card.dart';

/// A runtime that exists, so App settings has Tor to report on.
class _PresentRuntime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();
  void emit(TorStatus s) => _events.add(s);

  @override
  bool get isAvailable => true;
  @override
  Stream<TorStatus> get events => _events.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> rebuildCircuits() async {}
  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) async {}
  @override
  Future<int> startTransport(String transport) async => 0;
  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}
  @override
  Future<void> reopenListeners() async {}
}

final Uint8List _png64 =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));

void main() {
  Widget host({
    bool routerRunsHere = false,
    Map<String, String> siteNames = const {},
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
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
    // The Developer section's rows are only rendered once the flag is on.
    DeveloperModeService.instance.debugSet(true);
  });

  tearDown(() async {
    DeveloperModeService.instance.debugSet(false);
    for (final f in ExperimentalFeature.values) {
      ExperimentalFeaturesService.instance.debugSet(f, f.defaultOn);
    }
    await TorService.reset();
  });

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
    expect(prefs.getBool(kDeveloperModeKey), isFalse,
        reason: 'the flag must survive a restart');
  });

  group('Tor in App settings (TOR-004, TOR-007)', () {
    late _PresentRuntime runtime;

    setUp(() {
      runtime = _PresentRuntime();
      TorService.overrideEngine(
          TorEngine(runtime: runtime, sessionSecret: 's'));
      DeveloperModeService.instance.debugSet(false);
    });

    /// Brings the outbound proxy block and the card under it on screen. The
    /// list builds only what is on screen, and a stopped card has no height,
    /// so it is reached through the row after it.
    Future<void> scrollToCard(WidgetTester tester) async {
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Location picker'), 200,
          scrollable: scrollable);
      await tester.drag(scrollable, const Offset(0, 250));
      await tester.pumpAndSettle();
    }

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
      await TorService.instance.maybeStart('site-a');
      runtime.emit(const TorUp('127.0.0.1', 41337));
      await tester.pumpAndSettle();
      await scrollToCard(tester);
      expect(find.text('Tor'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('tapping the card opens what Tor is doing app-wide',
        (tester) async {
      await tester.pumpWidget(host(siteNames: const {'site-a': 'Mail'}));
      await tester.pumpAndSettle();
      await TorService.instance.syncHolders({'site-a'});
      runtime.emit(const TorUp('127.0.0.1', 41337));
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
          TorEngine(runtime: _PresentRuntime(), sessionSecret: 's'));
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
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

      DeveloperModeService.instance.debugSet(false);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Saved proxies'), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(savedProxies(ListTile), findsOneWidget,
          reason: 'the library is offered with developer mode off');

      DeveloperModeService.instance.debugSet(true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Experimental'), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(savedProxies(SwitchListTile), findsNothing,
          reason: 'saved proxies are not experimental');
    });

    testWidgets('offers Site tabs everywhere, off by default (TAB-012)',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
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
      expect(prefs.getBool(kExperimentalSiteTabsKey), isTrue);

      DeveloperModeService.instance.debugSet(false);
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
      expect(prefs.getBool(kExperimentalProxyRouterKey), isFalse);
    });

    testWidgets('offers Site icons only on every platform, off by default',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
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
      expect(prefs.getBool(kExperimentalSiteIconsOnlyKey), isTrue);
    });

    testWidgets('Reset icon cache forgets every cached icon', (tester) async {
      SharedPreferences.setMockInitialValues({
        'favicon_url_https://a.test/': 'https://a.test/icon.png',
        'favicon_svg_https://a.test/icon.svg': '<svg/>',
        'favicon_url_https://b.test/':
            'https://www.google.com/s2/favicons?domain=b.test&sz=256',
        kExperimentalProxyRouterKey: true,
      });
      await FaviconUrlCache.initialize();
      final files = MemoryFileStore();
      final previous = SiteIconStore.instance;
      addTearDown(() => SiteIconStore.instance = previous);
      SiteIconStore.instance = SiteIconStore(store: files);
      await SiteIconStore.instance.initialize();
      await SiteIconStore.instance.offer(
          'https://a.test/', SiteIcon(_png64, 64, 64),
          persist: true);

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final row = find.text('Reset icon cache');
      await tester.scrollUntilVisible(row, 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('favicon_')), isEmpty);
      expect(prefs.getBool(kExperimentalProxyRouterKey), isTrue,
          reason: 'only icon entries go');
      expect(SiteIconStore.instance.get('https://a.test/'), isNull);
      expect(await files.list(), isEmpty);
      expect(find.text('Icon cache cleared'), findsOneWidget);
    });
  });
}
