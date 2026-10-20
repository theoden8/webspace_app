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

  test('older omitted defaults migrate to explicit choices', () async {
    await AppPref.tabsEnabled.set(false);
    await AppPref.externalLinkMode.set('block');
    final legacy = WebViewModel.fromJson({
      'initUrl': 'https://example.org/',
    }, stateSetterF: null);
    expect(legacy.effectiveTabsEnabled, isTrue);
    expect(legacy.effectiveExternalLinkMode, ExternalLinkMode.inApp);
    final restored = WebViewModel.fromJson(legacy.toJson(), stateSetterF: null);
    expect(restored.tabsEnabled, isTrue);
    expect(restored.externalLinkMode, ExternalLinkMode.inApp);
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
    final prefs = await SharedPreferences.getInstance();
    final exported = readExportedAppPrefs(prefs);
    expect(exported['tabsEnabled'], isFalse);
    expect(exported['externalLinkMode'], 'browser');
    await AppPref.tabsEnabled.set(true);
    await AppPref.externalLinkMode.set('inApp');
    await writeExportedAppPrefs(prefs, values: exported);
    expect(AppPref.tabsEnabled.load(prefs), isFalse);
    expect(ExternalLinkMode.appDefault, ExternalLinkMode.browser);
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
    await tester.tap(find.text('Tabs'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<ExternalLinkMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in browser').last);
    await tester.pumpAndSettle();
    expect(site.effectiveTabsEnabled, isFalse);
    expect(site.effectiveExternalLinkMode, ExternalLinkMode.browser);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tabsEnabled'), isFalse);
    expect(prefs.getString('externalLinkMode'), 'browser');
  });

  for (final setting in ['Tabs', 'External links']) {
    testWidgets('$setting returning to app default is guarded and saved', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = WebViewModel(
        initUrl: 'https://example.org/',
        tabsEnabled: false,
        externalLinkMode: ExternalLinkMode.block,
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
                        useContainers: false,
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
      await tester.tap(
        setting == 'Tabs'
            ? find.byType(DropdownButton<Scoped<bool>>)
            : find.byType(DropdownButton<Scoped<ExternalLinkMode>>),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(setting == 'Tabs' ? 'App default (On)' : 'App default').last,
      );
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(site.tabsEnabled, isFalse);
      expect(site.externalLinkMode, ExternalLinkMode.block);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Settings'));
      await tester.pumpAndSettle();
      final restored = WebViewModel.fromJson(site.toJson(), stateSetterF: null);
      if (setting == 'Tabs') {
        expect(restored.tabsEnabled, isNull);
        expect(restored.externalLinkMode, ExternalLinkMode.block);
      } else {
        expect(restored.tabsEnabled, isFalse);
        expect(restored.externalLinkMode, isNull);
      }
    });
  }
}
