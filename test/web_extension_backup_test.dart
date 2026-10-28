import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/byte_size.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_backup.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/backup_prompts.dart';

import 'helpers/extension_packages.dart';
import 'helpers/fake_extension_engine.dart';
import 'helpers/fake_extension_folders.dart';
import 'helpers/localized.dart';

Map<String, Uint8List> _files(Map<String, String> text) => {
  for (final MapEntry(:key, :value) in text.entries)
    key: Uint8List.fromList(utf8.encode(value)),
};

ExtensionPackage _package({required String name, int noise = 0}) {
  final random = Random(name.hashCode);
  final read = readExtensionPackage(
    sampleZip(
      manifest: {'name': name, 'permissions': ['storage']},
      extra: {
        if (noise > 0)
          'noise.bin': Uint8List.fromList([
            for (var i = 0; i < noise; i++) random.nextInt(256),
          ]),
      },
    ),
  );
  return switch (read) {
    final ExtensionPackage p => p,
    PackageRefused(:final why) => fail('refused: $why'),
  };
}

BackupExtension _carried(
  String id, {
  required String fingerprint,
  Uint8List? package,
}) => BackupExtension(
  id: WebExtensionId(id),
  name: id,
  version: '1',
  fingerprint: fingerprint,
  package: package,
);

String _fp(String c) => c * 64;

/// Planted mistake: a fingerprint over the bytes alone, so files that split
/// the same bytes differently collide.
String _bytesOnlyFingerprint(Map<String, Uint8List> files) =>
    extensionFingerprint({
      'all': Uint8List.fromList([
        for (final path in files.keys.toList()..sort()) ...files[path]!,
      ]),
    });

/// Planted mistake: the backup's extensions linked by their ids, which name
/// another device's library.
ExtensionRelinkPlan _relinkById(
  BackupExtensions incoming, {
  required Map<String, WebExtensionId> library,
}) {
  final ids = library.values.toSet();
  return (
    linked: {
      for (final e in incoming.extensions)
        if (ids.contains(e.id)) e.id: e.id,
    },
    toAdd: [
      for (final e in incoming.extensions)
        if (!ids.contains(e.id) && e.package != null) e,
    ],
    missing: [
      for (final e in incoming.extensions)
        if (!ids.contains(e.id) && e.package == null) e,
    ],
  );
}

void main() {
  group('WEBEXT-011 an extension\'s fingerprint is its files', () {
    test('the same files give the same fingerprint, whatever their order',
        () {
      final a = _files({'manifest.json': '{}', 'content.js': 'x'});
      final b = _files({'content.js': 'x', 'manifest.json': '{}'});
      expect(extensionFingerprint(a), extensionFingerprint(b));
      expect(extensionFingerprint(a), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('a changed byte, path or split changes it', () {
      final base = _files({'a.js': 'ab', 'b.js': 'c'});
      final variants = [
        _files({'a.js': 'ab', 'b.js': 'd'}),
        _files({'a.js': 'ab', 'c.js': 'c'}),
        _files({'a.js': 'a', 'b.js': 'bc'}),
      ];
      for (final v in variants) {
        expect(extensionFingerprint(v), isNot(extensionFingerprint(base)));
      }
    });

    test('a fingerprint of the bytes alone is caught by the split row', () {
      expect(
        _bytesOnlyFingerprint(_files({'a.js': 'ab', 'b.js': 'c'})),
        _bytesOnlyFingerprint(_files({'a.js': 'a', 'b.js': 'bc'})),
      );
    });

    test('a packed extension reads back as the same files', () {
      final package = _package(name: 'Sample');
      final read = readExtensionPackage(packExtension(package.files));
      expect(read, isA<ExtensionPackage>());
      final files = (read as ExtensionPackage).files;
      expect(extensionFingerprint(files), extensionFingerprint(package.files));
    });
  });

  group('WEBEXT-011 each choice names what it adds to the backup', () {
    test('references add under a kilobyte; files add their packages', () {
      final big = _package(name: 'Big', noise: 1200 * 1024);
      final small = _package(name: 'Small', noise: 300 * 1024);
      WebExtensionEntry entry(String id, {required String name}) =>
          WebExtensionEntry(
            id: WebExtensionId(id),
            name: name,
            version: '1.0',
            permissions: const {},
            hosts: const {},
            everySite: false,
          );
      final offer = offerExtensionCarry([
        (entry: entry('we-big', name: 'Big'), files: big.files),
        (entry: entry('we-small', name: 'Small'), files: small.files),
      ]);
      expect(offer.count, 2);
      expect(offer.referencesBytes, lessThan(1024));
      final packed = packExtension(big.files).length +
          packExtension(small.files).length;
      expect(offer.filesBytes, greaterThan(packed * 4 ~/ 3));
      expect(offer.filesBytes, lessThan(packed * 4 ~/ 3 + 2048));
      expect(
        offer.referencesBytes,
        utf8.encode(jsonEncode(offer.references.toJson())).length,
      );
      expect(
        extensionSectionFor(ExtensionCarry.leaveOut, offer: offer),
        isNull,
      );
      expect(
        extensionSectionFor(ExtensionCarry.files, offer: offer)!
            .extensions
            .every((e) => e.package != null),
        isTrue,
      );
    });
  });

  group('WEBEXT-011 an import links what this device has, by fingerprint', () {
    final incoming = BackupExtensions(
      carry: ExtensionCarry.files,
      extensions: [
        _carried('we-here', fingerprint: _fp('a')),
        _carried('we-new', fingerprint: _fp('b'), package: Uint8List(1)),
        _carried('we-gone', fingerprint: _fp('c')),
        _carried('we-other', fingerprint: _fp('d')),
      ],
    );
    final library = {
      _fp('a'): WebExtensionId('we-local-1'),
      _fp('e'): WebExtensionId('we-other'),
    };

    String label(ExtensionRelinkPlan plan) => [
      for (final MapEntry(:key, :value) in plan.linked.entries) '$key>$value',
      for (final e in plan.toAdd) '+${e.id}',
      for (final e in plan.missing) '?${e.id}',
    ].join(' ');

    test('a match links, a package adds, the rest are missing', () {
      expect(
        label(planExtensionRelink(incoming, library: library)),
        'we-here>we-local-1 +we-new ?we-gone ?we-other',
      );
    });

    test('linking by id is caught: an id here names another extension', () {
      expect(
        label(_relinkById(incoming, library: library)),
        isNot(label(planExtensionRelink(incoming, library: library))),
      );
    });

    test('a site keeps its choices for linked extensions only, under their '
        'ids here', () {
      expect(
        relinkChoices(
          {
            WebExtensionId('we-here'): false,
            WebExtensionId('we-gone'): true,
          },
          links: {WebExtensionId('we-here'): WebExtensionId('we-local-1')},
        ),
        {WebExtensionId('we-local-1'): false},
      );
    });
  });

  group('WEBEXT-011 a backup carries extensions only as chosen', () {
    SettingsBackup backupWith(BackupExtensions? section) =>
        SettingsBackupService.createBackup(
          webViewModels: [
            WebViewModel(
              initUrl: 'https://mail.example.com/',
              webExtensionChoices: {WebExtensionId('we-here'): true},
            ),
          ],
          webspaces: [Webspace.all()],
          themeMode: 0,
          globalPrefs: {for (final p in AppPref.values) p.key: p.value},
          webExtensions: section,
        );

    test('files survive the file, and the sites\' choices are held', () {
      final section = BackupExtensions(
        carry: ExtensionCarry.files,
        extensions: [
          _carried(
            'we-here',
            fingerprint: _fp('a'),
            package: Uint8List.fromList([1, 2, 3]),
          ),
        ],
      );
      final read = SettingsBackupService.importFromJson(
        SettingsBackupService.exportToJson(backupWith(section)),
      )!;
      expect(read.webExtensions!.carry, ExtensionCarry.files);
      expect(read.webExtensions!.extensions.single.package, [1, 2, 3]);
      final plan = planSettingsImport(read);
      expect(plan.sites.single.webExtensionChoices, isEmpty,
          reason: 'nothing runs before the import links it');
      expect(plan.heldExtensionChoices.single.choices,
          {WebExtensionId('we-here'): true});
    });

    test('left out, there is no section and no choice is held', () {
      final json = SettingsBackupService.exportToJson(backupWith(null));
      expect(jsonDecode(json), isNot(contains('webExtensions')));
      final plan = planSettingsImport(SettingsBackupService.importFromJson(
        json,
      )!);
      expect(plan.heldExtensionChoices, isEmpty);
      expect(plan.sites.single.webExtensionChoices, isEmpty);
    });

    test('a section that does not read is no section', () {
      expect(BackupExtensions.fromJson({'carry': 'all'}), isNull);
      expect(
        BackupExtensions.fromJson({
          'carry': 'references',
          'extensions': [
            {'id': 'we-ok', 'fingerprint': _fp('a')},
            {'id': 'we-bad', 'fingerprint': 'short'},
            {'id': '../escape', 'fingerprint': _fp('b')},
          ],
        })!.extensions.map((e) => e.id),
        ['we-ok'],
      );
    });
  });

  group('WEBEXT-011 files restored on another device', () {
    late FakeExtensionFolders disk;
    final library = WebExtensionLibrary.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      debugHostRunsWebExtensions = true;
      DeveloperModeService.instance.debugSet(on: true);
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: true,
      );
      disk = FakeExtensionFolders();
      library.debugReset();
      await library.initialize(folders: disk, engine: FakeExtensionEngine());
    });

    /// The library of a device that never had these extensions.
    Future<void> anotherDevice() async {
      SharedPreferences.setMockInitialValues({});
      library.debugReset();
      await library.initialize(
        folders: FakeExtensionFolders(),
        engine: FakeExtensionEngine(),
      );
    }

    tearDown(() {
      debugHostRunsWebExtensions = null;
      DeveloperModeService.instance.debugSet(on: false);
      ExperimentalFeaturesService.instance.debugSet(
        ExperimentalFeature.webExtensions,
        on: false,
      );
    });

    test('the extension is added once accepted, the site runs it, and its '
        'default for every site is off', () async {
      final exported = await library.add(_package(name: 'Sample'));
      await library.setEverySite(exported.id, on: true);
      final offer = await library.carryOffer();
      final backup = SettingsBackupService.importFromJson(
        SettingsBackupService.exportToJson(
          SettingsBackupService.createBackup(
            webViewModels: [
              WebViewModel(
                initUrl: 'https://mail.example.com/',
                webExtensionChoices: {exported.id: true},
              ),
            ],
            webspaces: [Webspace.all()],
            themeMode: 0,
            globalPrefs: {for (final p in AppPref.values) p.key: p.value},
            webExtensions: extensionSectionFor(
              ExtensionCarry.files,
              offer: offer,
            ),
          ),
        ),
      )!;

      await anotherDevice();
      final plan = planSettingsImport(backup);
      List<String>? asked;
      final restored = await library.restoreFromBackup(
        plan.webExtensions!,
        confirmAdd: (packages) async {
          asked = [for (final p in packages) p.manifest.name];
          return true;
        },
      );
      expect(asked, ['Sample']);
      expect(restored.missing, 0);
      final added = library.installed.value.single.entry;
      expect(added.everySite, isFalse);
      final site = plan.heldExtensionChoices.single.site
        ..webExtensionChoices = relinkChoices(
          plan.heldExtensionChoices.single.choices,
          links: restored.links,
        );
      expect(site.webExtensionChoices, {added.id: true});
    });

    test('declined, nothing is added and the extension counts as missing',
        () async {
      final exported = await library.add(_package(name: 'Sample'));
      final offer = await library.carryOffer();
      await anotherDevice();
      final restored = await library.restoreFromBackup(
        offer.files,
        confirmAdd: (_) async => false,
      );
      expect(library.installed.value, isEmpty);
      expect(restored.links, isEmpty);
      expect(restored.missing, 1);
      expect(exported.id, isNotNull);
    });

    test('references relink to the same files already here, adding nothing',
        () async {
      final here = await library.add(_package(name: 'Sample'));
      final offer = await library.carryOffer();
      final restored = await library.restoreFromBackup(
        offer.references,
        confirmAdd: (_) async => fail('nothing to add'),
      );
      expect(restored.links, {here.id: here.id});
      expect(library.installed.value, hasLength(1));
    });
  });

  group('WEBEXT-011 the export asks, naming each choice\'s size', () {
    testWidgets('the dialog lists the three choices with their sizes, and '
        'answers the one picked', (tester) async {
      final offer = offerExtensionCarry([
        (
          entry: WebExtensionEntry(
            id: WebExtensionId('we-big'),
            name: 'Big',
            version: '1.0',
            permissions: const {},
            hosts: const {},
            everySite: false,
          ),
          files: _package(name: 'Big', noise: 1200 * 1024).files,
        ),
      ]);
      late BuildContext context;
      await pumpLocalized(tester, home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      }));
      final answer = DialogBackupPrompts(context).chooseExtensionCarry(offer);
      await tester.pumpAndSettle();
      expect(find.text('Leave them out'), findsOneWidget);
      expect(
        find.textContaining('Adds ${formatByteSize(offer.referencesBytes)}.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Adds ${formatByteSize(offer.filesBytes)}.'),
        findsOneWidget,
      );
      expect(formatByteSize(offer.filesBytes), endsWith('MB'));
      await tester.tap(find.text('With their files'));
      await tester.pumpAndSettle();
      expect(await answer, ExtensionCarry.files);
    });

    testWidgets('cancelling the dialog answers nothing, which cancels the '
        'export', (tester) async {
      late BuildContext context;
      await pumpLocalized(tester, home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      }));
      final answer = DialogBackupPrompts(context)
          .chooseExtensionCarry(offerExtensionCarry(const []));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await answer, isNull);
    });
  });
}
