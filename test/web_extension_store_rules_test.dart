import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/app_distribution.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/screens/app_extensions.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_source_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/web_extension_source.dart';

import 'helpers/amo_search_reply.dart';
import 'helpers/extension_packages.dart';
import 'helpers/extension_sources.dart';
import 'helpers/fake_extension_engine.dart';
import 'helpers/fake_extension_fetch.dart';
import 'helpers/fake_extension_folders.dart';
import 'helpers/localized.dart';

const _searchQuery =
    'https://addons.mozilla.org/api/v5/addons/search/?q=adblock&type=extension'
    '&app=firefox&sort=users&page=1&page_size=20&lang=en-US';
const _amoQuery = 'https://addons.mozilla.org/api/v5/addons/addon/adnauseam/';
const _amoFile =
    'https://addons.mozilla.org/firefox/downloads/file/4398765/adnauseam-3.24.2.xpi';

Uint8List _packageBytes({
  required String version,
  List<String> permissions = const ['storage'],
}) => sampleZip(
  manifest: {
    'name': 'AdNauseam',
    'version': version,
    'permissions': permissions,
  },
);

final _library = WebExtensionLibrary.instance;

void main() {
  late FakeExtensionFetch fetch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
    debugHostRunsWebExtensions = true;
    DeveloperModeService.instance.debugSet(on: true);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: true,
    );
    fetch = FakeExtensionFetch()
      ..replies[_searchQuery] = amoSearchReply
      ..replies[_amoQuery] = amoAddonReply()
      ..files[_amoFile] = _packageBytes(version: '3.24.2');
    _library.debugReset();
    await _library.initialize(
      folders: FakeExtensionFolders(),
      engine: FakeExtensionEngine(),
      fetch: fetch.call,
      read: (bytes) async => readExtensionPackage(bytes),
    );
  });

  tearDown(() {
    debugHostRunsWebExtensions = null;
    debugHostDistribution = null;
    DeveloperModeService.instance.debugSet(on: false);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: false,
    );
  });

  /// AdNauseam added from its listing at [version], as the add flow does.
  Future<void> addAt({required String version}) async {
    fetch.files[_amoFile] = _packageBytes(version: version);
    final release = switch (await _library.latest(
      AmoSource(slug: SourceName('adnauseam')),
    )) {
      SourceGot(value: final ReleaseFound found) => found,
      final other => fail('no release: $other'),
    };
    final package = switch (await _library.download(release.candidates.first)) {
      SourceGot(value: final ExtensionPackage p) => p,
      final other => fail('no package: $other'),
    };
    await _library.add(
      package,
      source: AmoSource(slug: SourceName('adnauseam')),
    );
  }

  group('WEBEXT-019 search and installs without asking, outside the App '
      'Store only', () {
    testWidgets('a build from the App Store offers neither', (tester) async {
      debugHostDistribution = AppDistribution.appStore;
      await pumpLocalized(
        tester,
        home: AppExtensionsScreen(pick: () async => null),
      );
      expect(find.text('Search addons.mozilla.org'), findsNothing);
      expect(find.text('Install updates without asking'), findsNothing);
      expect(find.text('Add from a link'), findsOneWidget);
    });

    testWidgets('a build from outside it searches, labels each result and '
        'hides none, and adds the one picked', (tester) async {
      debugHostDistribution = AppDistribution.direct;
      fetch.replies['https://addons.mozilla.org/api/v5/addons/addon/'
          'ublock-origin/'] = amoAddonReply(
        fileUrl: _amoFile,
      );
      await pumpLocalized(
        tester,
        home: AppExtensionsScreen(pick: () async => null),
      );
      expect(find.text('Install updates without asking'), findsOneWidget);
      await tester.tap(find.text('Search addons.mozilla.org'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'adblock');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('uBlock Origin'), findsOneWidget);
      expect(find.text('Runs in part'), findsWidgets);
      expect(find.text('Runs'), findsWidgets);
      expect(find.textContaining('Recommended by Mozilla'), findsWidgets);
      expect(find.textContaining('11,346,172 users'), findsOneWidget);

      await tester.tap(find.text('uBlock Origin'));
      await tester.pumpAndSettle();
      expect(find.text('Add AdNauseam?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      final source = _library.installed.value.single.entry.source;
      expect(source, isA<AmoSource>());
      expect((source! as AmoSource).slug, 'ublock-origin');
    });

    test('with the switch on outside the App Store, an update asking for '
        'nothing new installs at the check', () async {
      debugHostDistribution = AppDistribution.direct;
      await AppPref.webExtensionsAutoUpdate.set(true);
      await addAt(version: '3.9');
      fetch.files[_amoFile] = _packageBytes(version: '3.24.2');
      await _library.checkUpdates(now: DateTime.utc(2026, 10, 28));
      final entry = _library.installed.value.single.entry;
      expect(entry.version, '3.24.2');
      expect(entry.latest, isNull);
    });

    test('one asking for more still waits for the user', () async {
      debugHostDistribution = AppDistribution.direct;
      await AppPref.webExtensionsAutoUpdate.set(true);
      await addAt(version: '3.9');
      fetch.files[_amoFile] = _packageBytes(
        version: '3.24.2',
        permissions: ['storage', 'cookies'],
      );
      await _library.checkUpdates(now: DateTime.utc(2026, 10, 28));
      final entry = _library.installed.value.single.entry;
      expect(entry.version, '3.9');
      expect(entry.latest, '3.24.2');
    });

    test('a build from the App Store installs nothing on its own, whatever '
        'the stored switch says', () async {
      debugHostDistribution = AppDistribution.appStore;
      await AppPref.webExtensionsAutoUpdate.set(true);
      await addAt(version: '3.9');
      fetch.files[_amoFile] = _packageBytes(version: '3.24.2');
      await _library.checkUpdates(now: DateTime.utc(2026, 10, 28));
      final entry = _library.installed.value.single.entry;
      expect(entry.version, '3.9');
      expect(entry.latest, '3.24.2');
    });
  });
}
