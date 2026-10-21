import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
  });

  tearDown(() {
    AppPref.tabsEnabled.debugValue = true;
    AppPref.externalLinkMode.debugValue = 'inApp';
    AppPref.routeOutboundLinks.debugValue = false;
  });

  test(
    'following sites resolve live defaults; explicit sites retain choices',
    () async {
      final following = WebViewModel(initUrl: 'https://example.org/');
      final own = WebViewModel(
        initUrl: 'https://example.org/',
        tabsEnabled: true,
        externalLinkMode: ExternalLinkMode.inApp,
      );
      await AppPref.tabsEnabled.set(false);
      await AppPref.externalLinkMode.set('block');
      expect(following.effectiveTabsEnabled, isFalse);
      expect(following.effectiveExternalLinkMode, ExternalLinkMode.block);
      expect(own.effectiveTabsEnabled, isTrue);
      expect(own.effectiveExternalLinkMode, ExternalLinkMode.inApp);
      final restored = WebViewModel.fromJson(
        following.toJson(),
        stateSetterF: null,
      );
      expect(restored.tabsEnabled, isNull);
      expect(restored.externalLinkMode, isNull);
      expect(restored.effectiveTabsEnabled, isFalse);
      expect(restored.effectiveExternalLinkMode, ExternalLinkMode.block);
      final restoredOwn = WebViewModel.fromJson(
        own.toJson(),
        stateSetterF: null,
      );
      expect(restoredOwn.tabsEnabled, isTrue);
      expect(restoredOwn.externalLinkMode, ExternalLinkMode.inApp);
    },
  );

  test('external-link inheritance owns routing while explicit choices stay fixed', () async {
    final following = WebViewModel(initUrl: 'https://example.org/');
    final off = WebViewModel(
      initUrl: 'https://example.org/', routeOutboundLinks: false,
      externalLinkMode: ExternalLinkMode.inApp);
    final on = WebViewModel(
      initUrl: 'https://example.org/', routeOutboundLinks: true,
      externalLinkMode: ExternalLinkMode.inApp);
    for (final appValue in [true, false]) {
      await AppPref.routeOutboundLinks.set(appValue);
      final restored = WebViewModel.fromJson(following.toJson(), stateSetterF: null);
      expect(following.toJson().containsKey('routeOutboundLinks'), isTrue);
      expect(restored.routeOutboundLinks, isFalse);
      expect(restored.effectiveRouteOutboundLinks, appValue);
      expect(off.effectiveRouteOutboundLinks, isFalse);
      expect(on.effectiveRouteOutboundLinks, isTrue);
      expect(WebViewModel.fromJson(off.toJson(), stateSetterF: null)
          .routeOutboundLinks, isFalse);
    }
    off.externalLinkMode = null;
    on.externalLinkMode = null;
    await AppPref.routeOutboundLinks.set(true);
    expect(off.effectiveRouteOutboundLinks, isTrue);
    await AppPref.routeOutboundLinks.set(false);
    expect(on.effectiveRouteOutboundLinks, isFalse);
    off.externalLinkMode = ExternalLinkMode.inApp;
    on.externalLinkMode = ExternalLinkMode.inApp;
    expect(off.effectiveRouteOutboundLinks, isFalse);
    expect(on.effectiveRouteOutboundLinks, isTrue);
    await AppPref.routeOutboundLinks.set(true);
    await AppPref.externalLinkMode.set('browser');
    for (final mode in ExternalLinkMode.values) {
      following.externalLinkMode = mode;
      expect(following.effectiveRouteOutboundLinks, isFalse);
      expect(following.routeOutboundLinks, isFalse);
    }
  });

  test('older omitted defaults migrate to explicit choices', () async {
    await AppPref.tabsEnabled.set(false);
    await AppPref.externalLinkMode.set('block');
    await AppPref.routeOutboundLinks.set(true);
    final legacy = WebViewModel.fromJson({
      'initUrl': 'https://example.org/',
    }, stateSetterF: null);
    expect(legacy.effectiveTabsEnabled, isTrue);
    expect(legacy.effectiveExternalLinkMode, ExternalLinkMode.inApp);
    expect(legacy.routeOutboundLinks, isFalse);
    expect(legacy.effectiveRouteOutboundLinks, isFalse);
    final restored = WebViewModel.fromJson(legacy.toJson(), stateSetterF: null);
    expect(restored.tabsEnabled, isTrue);
    expect(restored.externalLinkMode, ExternalLinkMode.inApp);
    expect(restored.routeOutboundLinks, isFalse);
  });

  test('kiosk and archive restrictions apply after app inheritance', () async {
    final site = WebViewModel(
      initUrl: 'https://example.org/',
      kioskMode: true,
      isArchiveTier: true,
      routeOutboundLinks: true,
    );
    await AppPref.externalLinkMode.set('browser');
    expect(site.effectiveTabsEnabled, isFalse);
    expect(site.effectiveExternalLinkMode, ExternalLinkMode.inApp);
    expect(site.tabsEnabled, isNull);
    expect(site.externalLinkMode, isNull);
    await AppPref.externalLinkMode.set('block');
    expect(site.effectiveExternalLinkMode, ExternalLinkMode.block);
    expect(site.effectiveRouteOutboundLinks, isFalse);
    site.kioskMode = false;
    expect(site.effectiveTabsEnabled, isTrue);
  });

  test('app defaults persist and ride settings backup preferences', () async {
    await AppPref.tabsEnabled.set(false);
    await AppPref.externalLinkMode.set('browser');
    await AppPref.routeOutboundLinks.set(true);
    final prefs = await SharedPreferences.getInstance();
    final exported = readExportedAppPrefs(prefs);
    expect(exported['tabsEnabled'], isFalse);
    expect(exported['externalLinkMode'], 'browser');
    expect(exported['routeOutboundLinks'], isTrue);
    await AppPref.tabsEnabled.set(true);
    await AppPref.externalLinkMode.set('inApp');
    await AppPref.routeOutboundLinks.set(false);
    await writeExportedAppPrefs(prefs, values: exported);
    expect(AppPref.tabsEnabled.load(prefs), isFalse);
    expect(ExternalLinkMode.appDefault, ExternalLinkMode.browser);
    expect(AppPref.routeOutboundLinks.value, isTrue);
    await AppPref.externalLinkMode.set('unrecognized');
    expect(ExternalLinkMode.appDefault, ExternalLinkMode.inApp);
  });

  testWidgets('app behaviour edits persisted defaults and updates live sites', (
    tester,
  ) async {
    final site = WebViewModel(initUrl: 'https://example.org/');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppBehaviourScreen(
          onOpenLinkHandlingSettings: () {},
          homeShortcuts: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Site defaults'), findsNothing);
    expect(tester.getTopLeft(find.text('Tabs')).dy,
        greaterThan(tester.getTopLeft(find.text('Opening and navigation')).dy));
    await tester.scrollUntilVisible(find.text('Tabs'), 200);
    await tester.tap(find.text('Tabs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Route links to my sites'));
    await tester.pumpAndSettle();
    expect(site.effectiveRouteOutboundLinks, isTrue);
    await tester.tap(find.byType(DropdownButton<ExternalLinkMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in browser').last);
    await tester.pumpAndSettle();
    expect(site.effectiveTabsEnabled, isFalse);
    expect(site.effectiveExternalLinkMode, ExternalLinkMode.browser);
    expect(site.effectiveRouteOutboundLinks, isFalse);
    expect(find.text('Route links to my sites'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tabsEnabled'), isFalse);
    expect(prefs.getString('externalLinkMode'), 'browser');
    expect(prefs.getBool('routeOutboundLinks'), isTrue);
  });

  for (final setting in ['Tabs', 'External links', 'Route links to my sites']) {
    final action = setting == 'Route links to my sites'
        ? 'toggling' : 'returning to app default';
    testWidgets('$setting $action is guarded and saved', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = setting == 'Route links to my sites';
      final mode = routing ? ExternalLinkMode.inApp : ExternalLinkMode.block;
      final site = WebViewModel(
        initUrl: 'https://example.org/',
        tabsEnabled: false,
        externalLinkMode: mode,
        routeOutboundLinks: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      SettingsScreen(
                        webViewModel: site,
                        appTheme: WebViewTheme.system,
                        useContainers: routing,
                      ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Behaviour'));
      await tester.pumpAndSettle();
      final tile = find.ancestor(of: find.text(setting), matching: find.byType(ListTile));
      if (setting == 'External links') {
        await tester.tap(find.descendant(of: tile,
            matching: find.byType(DropdownButton<Scoped<ExternalLinkMode>>)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('App default').last);
      } else {
        final toggle = find.descendant(of: tile, matching: find.byType(Switch));
        if (routing) {
          await tester.tap(toggle);
        } else {
          await tester.longPress(toggle);
        }
      }
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(site.tabsEnabled, isFalse);
      expect(site.externalLinkMode, mode);
      expect(site.routeOutboundLinks, isTrue);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Settings'));
      await tester.pumpAndSettle();
      final restored = WebViewModel.fromJson(site.toJson(), stateSetterF: null);
      if (setting == 'Tabs') {
        expect(restored.tabsEnabled, isNull);
        expect(restored.externalLinkMode, ExternalLinkMode.block);
      } else if (setting == 'External links') {
        expect(restored.tabsEnabled, isFalse);
        expect(restored.externalLinkMode, isNull);
      } else {
        expect(restored.tabsEnabled, isFalse);
        expect(restored.externalLinkMode, mode);
        expect(restored.routeOutboundLinks, isFalse);
        expect(restored.effectiveRouteOutboundLinks, isFalse);
        await AppPref.routeOutboundLinks.set(true);
        expect(restored.effectiveRouteOutboundLinks, isFalse);
      }
    });
  }
}
