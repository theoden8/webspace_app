import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/screens/app_extension_entry.dart';
import 'package:webspace/screens/app_extensions.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_source_engine.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_source.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/extension_packages.dart';
import 'helpers/extension_sources.dart';
import 'helpers/fake_extension_engine.dart';
import 'helpers/fake_extension_fetch.dart';
import 'helpers/fake_extension_folders.dart';
import 'helpers/localized.dart';

const _amoQuery = 'https://addons.mozilla.org/api/v5/addons/addon/adnauseam/';
const _amoFile =
    'https://addons.mozilla.org/firefox/downloads/file/4398765/adnauseam-3.24.2.xpi';
const _gitHubQuery =
    'https://api.github.com/repos/example-dev/ext/releases/latest';

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
final _source = AmoSource(slug: SourceName('adnauseam'));

void main() {
  late FakeExtensionFolders disk;
  late FakeExtensionFetch fetch;

  Future<void> relaunch() async {
    _library.debugReset();
    await _library.initialize(
      folders: disk,
      engine: FakeExtensionEngine(),
      fetch: fetch.call,
      read: (bytes) async => readExtensionPackage(bytes),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    debugHostRunsWebExtensions = true;
    DeveloperModeService.instance.debugSet(on: true);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: true,
    );
    disk = FakeExtensionFolders();
    fetch = FakeExtensionFetch()
      ..replies[_amoQuery] = amoAddonReply()
      ..files[_amoFile] = _packageBytes(version: '3.24.2');
    await relaunch();
  });

  tearDown(() {
    debugHostRunsWebExtensions = null;
    DeveloperModeService.instance.debugSet(on: false);
    ExperimentalFeaturesService.instance.debugSet(
      ExperimentalFeature.webExtensions,
      on: false,
    );
  });

  /// AdNauseam added from its listing at [version], as the add flow does.
  Future<WebExtensionEntry> addFromListing({String version = '3.24.2'}) async {
    fetch.files[_amoFile] = _packageBytes(version: version);
    final release = switch (await _library.latest(_source)) {
      SourceGot(value: final ReleaseFound found) => found,
      final other => fail('no release: $other'),
    };
    final package = switch (await _library.download(release.candidates.first)) {
      SourceGot(value: final ExtensionPackage p) => p,
      final other => fail('no package: $other'),
    };
    return _library.add(package, source: _source);
  }

  group('WEBEXT-017 an extension added from a link keeps its source', () {
    test('a listing\'s current file is downloaded and read, and the entry '
        'names the listing after a relaunch', () async {
      final entry = await addFromListing();
      expect(fetch.asked.map((u) => '$u'), [_amoQuery, _amoFile]);
      expect(entry.version, '3.24.2');
      await relaunch();
      final kept = _library.installed.value.single.entry;
      expect(kept.source, isA<AmoSource>());
      expect(kept.source!.label, 'addons.mozilla.org/firefox/addon/adnauseam');
    });

    test('a source that cannot be reached adds nothing and says why', () async {
      fetch.failing = 'Connection refused';
      expect(
        await _library.latest(_source),
        isA<SourceFailed<ReleaseRead>>().having(
          (f) => f.reason,
          'reason',
          'Connection refused',
        ),
      );
      expect(_library.installed.value, isEmpty);
    });

    testWidgets('the screen adds from a pasted link after the summary', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        home: AppExtensionsScreen(pick: () async => null),
      );
      await tester.tap(find.text('Add from a link'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'https://example.com/x');
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not a link the app reads'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'https://addons.mozilla.org/en-US/firefox/addon/adnauseam/',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Add AdNauseam?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(_library.installed.value.single.entry.source, isA<AmoSource>());
      expect(find.text('AdNauseam added'), findsOneWidget);
    });

    testWidgets('a GitHub release with several packages asks which, and '
        'remembers the kind picked', (tester) async {
      fetch.replies[_gitHubQuery] = extReleaseReply();
      fetch.files['https://github.com/example-dev/ext/releases/download/'
              'v2.1.0/ext-2.1.0.crx'] =
          _packageBytes(version: '2.1.0');
      await pumpLocalized(
        tester,
        home: AppExtensionsScreen(pick: () async => null),
      );
      await tester.tap(find.text('Add from a link'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://github.com/example-dev/ext',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Version 2.1.0: which file?'), findsOneWidget);
      final names = tester
          .widgetList<ListTile>(
            find.descendant(
              of: find.byType(SimpleDialog),
              matching: find.byType(ListTile),
            ),
          )
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(names.first, 'ext-2.1.0.crx');
      await tester.tap(find.text('ext-2.1.0.crx'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      final source = _library.installed.value.single.entry.source;
      expect(source, isA<GitHubSource>());
      expect((source! as GitHubSource).asset, 'ext-*.crx');
    });
  });

  group('WEBEXT-018 updates are checked once a day; one installs when asked',
      () {
    test('a newer release marks the entry, and a check the same day reads '
        'nothing', () async {
      final entry = await addFromListing(version: '3.9');
      fetch.asked.clear();
      final morning = DateTime.utc(2026, 10, 28, 9);
      await _library.checkUpdates(now: morning);
      expect(fetch.asked.map((u) => '$u'), [_amoQuery]);
      final checked = _library.installed.value.single.entry;
      expect(checked.latest, '3.24.2');
      expect(checked.checkedAt, morning);
      expect(checked.id, entry.id);

      fetch.asked.clear();
      await _library.checkUpdates(now: morning.add(const Duration(hours: 5)));
      expect(fetch.asked, isEmpty);
    });

    test('a source that cannot be reached is read again next time', () async {
      await addFromListing(version: '3.9');
      fetch.failing = 'timed out';
      await _library.checkUpdates(now: DateTime.utc(2026, 10, 28));
      expect(_library.installed.value.single.entry.checkedAt, isNull);
    });

    test('an update keeps its id, its default and its sites, and loads '
        'again as a new revision', () async {
      final entry = await addFromListing(version: '3.9');
      await _library.setEverySite(entry.id, on: true);
      await _library.checkUpdates(now: DateTime.utc(2026, 10, 28));
      final site = WebViewModel(initUrl: 'https://mail.example.com/');
      final before = (site.extensionPlan as AttachExtensions).loads.single;
      expect(before.revision, '3.9');
      fetch.files[_amoFile] = _packageBytes(version: '3.24.2');

      final ready = await _library.prepareUpdate(entry.id);
      expect(ready, isA<UpdateReady>());
      final update = ready as UpdateReady;
      expect(update.asks, isA<AsksNothingNew>());
      final updated = await _library.install(entry.id, package: update.package);

      expect(updated.id, entry.id);
      expect(updated.version, '3.24.2');
      expect(updated.everySite, isTrue);
      expect(updated.latest, isNull);
      expect(updated.source, isA<AmoSource>());
      final after = (site.extensionPlan as AttachExtensions).loads.single;
      expect(after.id, entry.id);
      expect(after.folder, before.folder);
      expect(after.revision, '3.24.2');
      expect(
        utf8.decode(disk.folders[entry.id]!['manifest.json']!),
        contains('"version":"3.24.2"'),
        reason: 'the new files are in its folder',
      );
    });

    test('an update that asks for more names what it adds', () async {
      final entry = await addFromListing(version: '3.9');
      fetch.files[_amoFile] = _packageBytes(
        version: '3.24.2',
        permissions: ['storage', 'cookies'],
      );
      final ready = await _library.prepareUpdate(entry.id) as UpdateReady;
      expect(
        ready.asks,
        isA<AsksMore>().having((a) => a.permissions, 'permissions', {
          'cookies',
        }),
      );
      expect(
        _library.installed.value.single.entry.version,
        '3.9',
        reason: 'nothing installs before the user accepts',
      );
    });

    testWidgets('the entry screen shows the source and the update, and an '
        'update asking for more waits for the user', (tester) async {
      final entry = await addFromListing(version: '3.9');
      await _library.checkUpdates(now: DateTime.utc(2026, 10, 28));
      fetch.files[_amoFile] = _packageBytes(
        version: '3.24.2',
        permissions: ['storage', 'cookies'],
      );
      await pumpLocalized(tester, home: ExtensionEntryScreen(id: entry.id));
      await tester.pumpAndSettle();
      expect(find.textContaining('addons.mozilla.org/firefox/addon/adnauseam'),
          findsOneWidget);
      await tester.tap(find.text('Update to 3.24.2'));
      await tester.pumpAndSettle();
      expect(find.text('Update AdNauseam?'), findsOneWidget);
      expect(find.textContaining('It asks for: cookies'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_library.installed.value.single.entry.version, '3.9');

      await tester.tap(find.text('Update to 3.24.2'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Update'));
      await tester.pumpAndSettle();
      expect(_library.installed.value.single.entry.version, '3.24.2');
      expect(find.text('AdNauseam updated to 3.24.2'), findsOneWidget);
    });
  });
}
