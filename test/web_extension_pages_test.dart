import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/extension_packages.dart';
import 'helpers/fake_extension_engine.dart';
import 'helpers/fake_extension_folders.dart';
import 'helpers/isolations.dart';

ExtensionPackage _package({required String name}) =>
    switch (readExtensionPackage(sampleZip(manifest: {
      'name': name,
      'permissions': ['storage'],
    }))) {
      final ExtensionPackage package => package,
      PackageRefused(:final why) => fail('refused: $why'),
    };

const ExtensionReport _clean = (
  problems: [],
  hasOptionsPage: true,
  hasAction: true,
  loadsHere: true,
);

final _library = WebExtensionLibrary.instance;

void main() {
  late FakeExtensionFolders disk;
  late FakeExtensionEngine engine;

  /// The library as the next launch reads it.
  Future<void> relaunch() async {
    _library.debugReset();
    await _library.initialize(folders: disk, engine: engine);
    await pumpEventQueue();
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
    engine = FakeExtensionEngine()..anyFolder = _clean;
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

  WebViewModel site(
    String url, {
    required Set<WebExtensionId> on,
    bool incognito = false,
  }) => WebViewModel(
    initUrl: url,
    incognito: incognito,
    webExtensionChoices: {for (final id in on) id: true},
  );

  group('WEBEXT-003 what WebKit reports of an extension is on its entry', () {
    test('it is read on import and again at each launch', () async {
      engine.anyFolder = (
        problems: ['Unsupported manifest entry: sidebar_action'],
        hasOptionsPage: false,
        hasAction: true,
        loadsHere: true,
      );
      final entry = await _library.add(_package(name: 'Sample'));
      expect(
        _library.reports.value[entry.id]?.problems,
        ['Unsupported manifest entry: sidebar_action'],
      );

      engine.reports[disk.folderOf(entry.id)] = _clean;
      await relaunch();
      expect(_library.reports.value[entry.id], _clean);
      expect(engine.inspected, [disk.folderOf(entry.id), disk.folderOf(entry.id)]);
    });

    test('an extension WebKit reads nothing of is still offered', () async {
      engine.anyFolder = null;
      final entry = await _library.add(_package(name: 'Sample'));
      expect(_library.reports.value, isEmpty);
      final plan = site('https://mail.example.com/', on: {entry.id})
          .extensionPlan;
      expect(plan, isA<AttachExtensions>());
    });
  });

  group('WEBEXT-003 an extension WebKit does not load here runs nowhere', () {
    /// On iPhone and iPad WebKit refuses an extension whose background
    /// stays loaded, though it reads it. A site that switched one on
    /// attached it anyway and offered its pages, which never opened.
    test('no site attaches it and none of its pages is offered', () async {
      engine.anyFolder = (
        problems: ['Invalid `persistent` manifest entry.'],
        hasOptionsPage: true,
        hasAction: true,
        loadsHere: false,
      );
      final refused = await _library.add(_package(name: 'Refused'));
      engine.anyFolder = _clean;
      final runs = await _library.add(_package(name: 'Runs'));
      expect(_library.loadsHere(refused.id), isFalse);

      final home = site(
        'https://mail.example.com/',
        on: {refused.id, runs.id},
      ).extensionHome(fakeContainers())!;
      expect([for (final load in home.plan.loads) load.id], [runs.id]);
      for (final page in ExtensionPage.values) {
        expect([
          for (final e in _library.offering(page, home: home)) e.name,
        ], ['Runs']);
      }
      expect(
        site('https://mail.example.com/', on: {refused.id}).extensionPlan,
        isA<NoExtensions>(),
      );
    });
  });

  group('an extension\'s pages open within its site', () {
    test('a site offers the pages WebKit reports of what it runs', () async {
      final both = await _library.add(_package(name: 'Both'));
      engine.anyFolder = (
        problems: [],
        hasOptionsPage: true,
        hasAction: false,
        loadsHere: true,
      );
      final options = await _library.add(_package(name: 'Options'));
      final off = await _library.add(_package(name: 'Off'));
      final home = site(
        'https://mail.example.com/',
        on: {both.id, options.id},
      ).extensionHome(fakeContainers())!;
      expect(
        [for (final e in _library.offering(ExtensionPage.options, home: home))
          e.name],
        ['Both', 'Options'],
      );
      expect(
        [for (final e in _library.offering(ExtensionPage.action, home: home))
          e.name],
        ['Both'],
      );
      expect(
        _library.offering(ExtensionPage.options, home: home),
        isNot(contains(predicate<WebExtensionEntry>((e) => e.id == off.id))),
      );
    });

    test('a page opens in the site\'s own container, with its plan', () async {
      final entry = await _library.add(_package(name: 'Sample'));
      final mail = site('https://mail.example.com/', on: {entry.id});
      final home = mail.extensionHome(fakeContainers())!;
      expect(home.container, mail.boundContainerId(fakeContainers()));
      expect(
        await _library.open(ExtensionPage.options, extension: entry.id, home: home),
        isTrue,
      );
      expect(engine.shown.single.page, ExtensionPage.options);
      expect(engine.shown.single.home.plan.loads.single.id, entry.id);
    });

    test('a site whose extensions keep nothing opens none of their pages',
        () async {
      final entry = await _library.add(_package(name: 'Sample'));
      expect(
        site('https://mail.example.com/', on: {entry.id}, incognito: true)
            .extensionHome(fakeContainers()),
        isNull,
        reason: 'an incognito site\'s extensions keep nothing',
      );
      expect(
        site('https://mail.example.com/', on: {entry.id})
            .extensionHome(fakeSharedJar()),
        isNull,
        reason: 'the shared jar has no container to keep it in',
      );
      expect(
        site('https://mail.example.com/', on: const {})
            .extensionHome(fakeContainers()),
        isNull,
      );
    });
  });

  group('WEBEXT-002 removing an extension deletes it everywhere', () {
    test('its files and its data on both sites go, and it runs on neither',
        () async {
      final gone = await _library.add(_package(name: 'Gone'));
      final kept = await _library.add(_package(name: 'Kept'));
      final mail = site('https://mail.example.com/', on: {gone.id, kept.id});
      final docs = site('https://docs.example.org/', on: {gone.id});
      for (final s in [mail, docs]) {
        await _library.open(
          ExtensionPage.options,
          extension: gone.id,
          home: s.extensionHome(fakeContainers())!,
        );
      }
      await _library.open(
        ExtensionPage.options,
        extension: kept.id,
        home: mail.extensionHome(fakeContainers())!,
      );
      expect(engine.stored.values.where((ids) => ids.contains(gone.id)),
          hasLength(2));

      await _library.remove(gone.id);
      expect(
        engine.stored.values.where((ids) => ids.contains(gone.id)),
        isEmpty,
      );
      expect(engine.stored[mail.boundContainerId(fakeContainers())], {kept.id});
      expect(disk.folders.keys, [kept.id]);
      expect(_library.reports.value.keys, [kept.id]);
      expect(
        (mail.extensionPlan as AttachExtensions).loads.map((l) => l.id),
        [kept.id],
      );
      expect(docs.extensionPlan, isA<NoExtensions>());
    });
  });
}
