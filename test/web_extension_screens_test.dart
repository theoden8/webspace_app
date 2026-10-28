import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/screens/app_extensions.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/site_extensions.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/extension_packages.dart';
import 'helpers/fake_extension_engine.dart';
import 'helpers/fake_extension_folders.dart';
import 'helpers/isolations.dart';
import 'helpers/localized.dart';

final _manifest = {
  'name': 'Sample',
  'description': 'Tidies pages.',
  'permissions': ['storage', 'nativeMessaging'],
  'host_permissions': ['<all_urls>'],
};

Future<PackageRead> _readHere(Uint8List bytes) async =>
    readExtensionPackage(bytes);

AppExtensionsScreen _library({required Uint8List? picked}) =>
    AppExtensionsScreen(pick: () async => picked, read: _readHere);

Future<WebExtensionEntry> _imported() async => WebExtensionLibrary.instance.add(
  switch (readExtensionPackage(sampleZip(manifest: _manifest))) {
    final ExtensionPackage package => package,
    PackageRefused(:final why) => fail('refused: $why'),
  },
);

Widget _appSettings() => localizedApp(
  AppSettingsScreen(
    currentSettings: AppThemeSettings(),
    containersRunHere: true,
    externalTorRunsHere: false,
    proxyRouterRunsHere: false,
    torSites: const {},
    onSettingsChanged: (_) {},
    onExportSettings: () {},
    onImportSettings: () {},
    onOpenLinkHandlingSettings: () {},
    homeShortcuts: null,
    webSearchSites: const [],
  ),
);

Future<void> _tapText(WidgetTester tester, {required String text}) async {
  final target = find.text(text);
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// The dialog's text, every line of it.
String _dialogText(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)),
  ))
    text.data ?? '',
].join('\n');

void main() {
  late FakeExtensionFolders disk;
  late FakeExtensionEngine engine;

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
    disk = FakeExtensionFolders();
    WebExtensionLibrary.instance.debugReset();
    engine = FakeExtensionEngine();
    await WebExtensionLibrary.instance.initialize(
      folders: disk,
      engine: engine,
    );
    debugHostRunsWebExtensions = true;
    DeveloperModeService.instance.debugSet(on: true);
  });

  tearDown(() {
    debugHostRunsWebExtensions = null;
    DeveloperModeService.instance.debugSet(on: false);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: false,
    );
  });

  group('WEBEXT-001 offered only where WebKit runs extensions, as an '
      'experiment', () {
    testWidgets('the Developer screen offers the switch, off by default', (
      tester,
    ) async {
      await tester.pumpWidget(_appSettings());
      await tester.pumpAndSettle();
      expect(find.text('Extensions'), findsNothing);
      await _tapText(tester, text: 'Developer');
      await tester.scrollUntilVisible(
        find.text('Web extensions'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final row = find.ancestor(
        of: find.text('Web extensions'),
        matching: find.byType(SwitchListTile),
      );
      expect(tester.widget<SwitchListTile>(row).value, isFalse);
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(webExtensionsOffered, isTrue);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Extensions'), findsOneWidget);
      expect(find.text('None imported'), findsOneWidget);
    });

    testWidgets('a host that runs none has no switch and no row', (
      tester,
    ) async {
      debugHostRunsWebExtensions = false;
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: true,
      );
      await tester.pumpWidget(_appSettings());
      await tester.pumpAndSettle();
      expect(find.text('Extensions'), findsNothing);
      await _tapText(tester, text: 'Developer');
      expect(find.text('Web extensions'), findsNothing);
    });
  });

  group('an extension comes from a file the user picks', () {
    testWidgets('a Chrome package is summed up, then added on confirm', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        home: _library(picked: crx3Of(sampleZip(manifest: _manifest))),
      );
      await tester.tap(find.text('Import from a file'));
      await tester.pumpAndSettle();

      expect(find.text('Add Sample?'), findsOneWidget);
      final summary = _dialogText(tester);
      expect(summary, contains('Version 1.0'));
      expect(summary, contains('Tidies pages.'));
      expect(summary, contains('It asks for: nativeMessaging, storage'));
      expect(summary, contains('Pages it asks to reach: <all_urls>'));
      expect(summary, contains('the app does not check the signature'));
      expect(
        WebExtensionLibrary.instance.installed.value,
        isEmpty,
        reason: 'nothing is added before the user says so',
      );

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      final installed = WebExtensionLibrary.instance.installed.value;
      expect([for (final i in installed) i.entry.name], ['Sample']);
      expect(disk.folders.keys, [installed.single.entry.id]);
      expect(find.text('Sample'), findsOneWidget);
      expect(find.text('Sample added'), findsOneWidget);
    });

    testWidgets('a cancelled summary adds nothing', (tester) async {
      await pumpLocalized(
        tester,
        home: _library(picked: sampleZip(manifest: _manifest)),
      );
      await tester.tap(find.text('Import from a file'));
      await tester.pumpAndSettle();
      expect(
        _dialogText(tester),
        isNot(contains('signature')),
        reason: 'a plain zip carries none',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(WebExtensionLibrary.instance.installed.value, isEmpty);
      expect(disk.folders, isEmpty);
    });

    testWidgets('a file that is not an extension is refused, saying why', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        home: _library(picked: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])),
      );
      await tester.tap(find.text('Import from a file'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text('Not imported: the file is not a .crx, .xpi or .zip package'),
        findsOneWidget,
      );
      expect(WebExtensionLibrary.instance.installed.value, isEmpty);
    });

    testWidgets('removing an extension deletes it from the library', (
      tester,
    ) async {
      final entry = await _imported();
      await pumpLocalized(tester, home: _library(picked: null));
      expect(find.text('Sample'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Sample?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(WebExtensionLibrary.instance.installed.value, isEmpty);
      expect(disk.folders.containsKey(entry.id), isFalse);
      expect(find.text('Sample'), findsNothing);
    });
  });

  group('WEBEXT-004 an extension runs on a site once switched on there', () {
    testWidgets('switching on asks first, showing what the site grants', (
      tester,
    ) async {
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: true,
      );
      final entry = await _imported();
      final site = WebViewModel(initUrl: 'https://mail.example.com/');
      var changes = 0;
      await pumpLocalized(
        tester,
        home: SiteExtensionsScreen(
          site: site,
          isolation: fakeContainers(),
          onChanged: () => changes++,
        ),
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Run Sample on this site?'), findsOneWidget);
      final consent = _dialogText(tester);
      expect(consent, contains('*://*.example.com/*'));
      expect(consent, contains('It gets: storage'));
      expect(consent, isNot(contains('nativeMessaging')));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        site.enabledWebExtensions,
        isEmpty,
        reason: 'nothing is switched on before the user says so',
      );
      expect(changes, 0);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch on'));
      await tester.pumpAndSettle();
      expect(site.enabledWebExtensions, {entry.id});
      expect(changes, 1);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'switching off asks nothing',
      );
      expect(site.enabledWebExtensions, isEmpty);
      expect(changes, 2);
    });
  });

  group('WEBEXT-009 archive-tier and kiosk sites run no extension', () {
    Future<void> openSettings(
      WidgetTester tester, {
      required WebViewModel site,
    }) async {
      setViewSize(tester, size: const Size(1000, 4000));
      await tester.pumpWidget(
        localizedApp(
          SettingsScreen(
            webViewModel: site,
            appTheme: WebViewTheme.system,
            isolation: fakeContainers(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String rowSubtitle(WidgetTester tester) {
      final row = find.ancestor(
        of: find.text('Extensions'),
        matching: find.byType(ListTile),
      );
      return (tester.widget<ListTile>(row).subtitle! as Text).data!;
    }

    setUp(() async {
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: true,
      );
    });

    testWidgets('a site switched on counts what runs on it', (tester) async {
      final entry = await _imported();
      await openSettings(
        tester,
        site: WebViewModel(
          initUrl: 'https://mail.example.com/',
          enabledWebExtensions: {entry.id},
        ),
      );
      expect(rowSubtitle(tester), '1 on');
    });

    testWidgets('an archive-tier site\'s row is locked, naming the archive', (
      tester,
    ) async {
      final entry = await _imported();
      final site = WebViewModel(
        initUrl: 'https://mail.example.com/',
        enabledWebExtensions: {entry.id},
        isArchiveTier: true,
      );
      await openSettings(tester, site: site);
      expect(rowSubtitle(tester), 'Fixed for sites in an archive');
      expect(siteExtensionsOn(site.extensionPlan), 0);
    });

    testWidgets('a kiosk site\'s row is locked, naming Kiosk mode', (
      tester,
    ) async {
      final entry = await _imported();
      final site = WebViewModel(
        initUrl: 'https://mail.example.com/',
        enabledWebExtensions: {entry.id},
        kioskMode: true,
      );
      await openSettings(tester, site: site);
      expect(rowSubtitle(tester), 'Off while Kiosk mode is on');
      expect(siteExtensionsOn(site.extensionPlan), 0);
    });
  });

  group('WEBEXT-012 with the experiment off the screens are hidden', () {
    testWidgets('a site keeps its choice, and its row is gone', (tester) async {
      final entry = await _imported();
      final site = WebViewModel(
        initUrl: 'https://mail.example.com/',
        enabledWebExtensions: {entry.id},
      );
      setViewSize(tester, size: const Size(1000, 4000));
      await tester.pumpWidget(
        localizedApp(
          SettingsScreen(
            webViewModel: site,
            appTheme: WebViewTheme.system,
            isolation: fakeContainers(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Extensions'), findsNothing);
      expect(site.enabledWebExtensions, {entry.id});
    });
  });

  group('WEBEXT-003 an entry lists what WebKit reported', () {
    testWidgets('its problems are counted, and listed behind its hint', (
      tester,
    ) async {
      engine.anyFolder = (
        problems: [
          'Unsupported manifest entry: sidebar_action',
          'Unsupported permission: webRequestBlocking',
        ],
        hasOptionsPage: false,
        hasAction: false,
      );
      await _imported();
      await pumpLocalized(tester, home: _library(picked: null));
      expect(find.text('Version 1.0 · 2 problems reported'), findsOneWidget);
      await tester.tap(find.byTooltip('Sample'));
      await tester.pumpAndSettle();
      final hint = _dialogText(tester);
      expect(hint, contains('Unsupported manifest entry: sidebar_action'));
      expect(hint, contains('Unsupported permission: webRequestBlocking'));
    });

    testWidgets('an extension read cleanly shows its version alone', (
      tester,
    ) async {
      engine.anyFolder = (
        problems: const <String>[],
        hasOptionsPage: false,
        hasAction: false,
      );
      await _imported();
      await pumpLocalized(tester, home: _library(picked: null));
      expect(find.text('Version 1.0'), findsOneWidget);
      expect(find.byTooltip('Sample'), findsNothing);
    });
  });

  group('an extension\'s own UI opens within its site', () {
    setUp(() {
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: true,
      );
      engine.anyFolder = (
        problems: const <String>[],
        hasOptionsPage: true,
        hasAction: true,
      );
    });

    testWidgets('the site\'s Extensions screen opens its settings and its '
        'action over the site', (tester) async {
      final entry = await _imported();
      final site = WebViewModel(
        initUrl: 'https://mail.example.com/',
        enabledWebExtensions: {entry.id},
      );
      await pumpLocalized(
        tester,
        home: SiteExtensionsScreen(
          site: site,
          isolation: fakeContainers(),
          onChanged: () {},
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        [for (final s in engine.shown) (s.page, s.extension, s.home.container)],
        [
          for (final page in [ExtensionPage.options, ExtensionPage.action])
            (page, entry.id, site.boundContainerId(fakeContainers())),
        ],
      );
    });

    testWidgets('a page that cannot open says so', (tester) async {
      final entry = await _imported();
      engine.reports[WebExtensionLibrary.instance.installed.value.single
          .folder] = (
        problems: const <String>[],
        hasOptionsPage: false,
        hasAction: true,
      );
      await pumpLocalized(
        tester,
        home: SiteExtensionsScreen(
          site: WebViewModel(
            initUrl: 'https://mail.example.com/',
            enabledWebExtensions: {entry.id},
          ),
          isolation: fakeContainers(),
          onChanged: () {},
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(engine.shown, isEmpty);
      expect(find.text('Sample could not open here'), findsOneWidget);
    });

    testWidgets('an extension the site does not run offers no page', (
      tester,
    ) async {
      await _imported();
      await pumpLocalized(
        tester,
        home: SiteExtensionsScreen(
          site: WebViewModel(initUrl: 'https://mail.example.com/'),
          isolation: fakeContainers(),
          onChanged: () {},
        ),
      );
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Open'), findsNothing);
    });

    testWidgets('the site\'s menu lists the extension, which opens its '
        'action', (tester) async {
      final entry = await _imported();
      final site = WebViewModel(
        initUrl: 'https://mail.example.com/',
        enabledWebExtensions: {entry.id},
      );
      await pumpLocalized(
        tester,
        home: Scaffold(
          appBar: AppBar(
            actions: [
              SiteMenuButton(
                placement: SiteMenuPlacement.appBar,
                state: () => (
                  loading: false,
                  tabsOn: false,
                  fullscreen: false,
                  offersShortcut: false,
                  extensions: siteMenuExtensions(
                    site,
                    isolation: fakeContainers(),
                  ),
                ),
                nav: (
                  back: () {},
                  home: null,
                  share: () {},
                  reload: () {},
                  stop: () {},
                  backInNewTab: null,
                  duplicateTab: null,
                ),
                onSelected: (_) => fail('an extension is no menu action'),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.byType(SiteMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sample'));
      await tester.pumpAndSettle();
      expect(engine.shown.single.page, ExtensionPage.action);
      expect(engine.shown.single.extension, entry.id);
    });

    testWidgets('a site whose extensions keep nothing lists none in its menu',
        (tester) async {
      final entry = await _imported();
      expect(
        siteMenuExtensions(
          WebViewModel(
            initUrl: 'https://mail.example.com/',
            enabledWebExtensions: {entry.id},
            incognito: true,
          ),
          isolation: fakeContainers(),
        ),
        isEmpty,
      );
    });
  });
}
