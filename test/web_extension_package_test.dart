import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/web_extension_package_engine.dart';

import 'helpers/extension_packages.dart';

ExtensionPackage _read(Uint8List bytes) =>
    switch (readExtensionPackage(bytes)) {
      final ExtensionPackage package => package,
      PackageRefused(:final why) => fail('refused: $why'),
    };

PackageRefusal _refusal(Uint8List bytes) =>
    switch (readExtensionPackage(bytes)) {
      final ExtensionPackage package => fail('read ${package.files.keys}'),
      PackageRefused(:final why) => why,
    };

EntryProblem _unsafe(Uint8List bytes) => switch (_refusal(bytes)) {
  UnsafeEntry(:final problem) => problem,
  final other => fail('not an unsafe entry: $other'),
};

PackageFeature _unsupported(Uint8List bytes) => switch (_refusal(bytes)) {
  UnsupportedPackage(:final feature) => feature,
  final other => fail('not unsupported: $other'),
};

ManifestProblem _manifestProblem(String manifest) =>
    switch (_refusal(zipOf([ZipEntryBytes('manifest.json', text: manifest)]))) {
      BadManifest(:final problem) => problem,
      final other => fail('not a bad manifest: $other'),
    };

ExtensionManifest _manifest(
  Map<String, Object?> manifest, {
  List<ZipEntryBytes> also = const [],
}) => _read(
  zipOf([ZipEntryBytes('manifest.json', text: jsonEncode(manifest)), ...also]),
).manifest;

/// [zip] with its end of central directory record's 16-bit field at
/// [offset] set to [value].
Uint8List _patchEnd(Uint8List zip, {required int offset, required int value}) {
  final copy = Uint8List.fromList(zip);
  ByteData.sublistView(
    copy,
  ).setUint16(copy.length - 22 + offset, value, Endian.little);
  return copy;
}

/// The envelope rows: each a package and where its archive starts, or why
/// there is none.
final _envelopeRows = <(String, Uint8List, String)>[
  ('zip', sampleZip(), 'zip@0'),
  ('crx3, empty header', crx3Of(sampleZip(), headerLength: 0), 'crx3@12'),
  ('crx3', crx3Of(sampleZip()), 'crx3@76'),
  ('crx2', crx2Of(sampleZip(), keyLength: 10, signatureLength: 20), 'crx2@46'),
  (
    'crx version 4',
    Uint8List.fromList([...ascii.encode('Cr24'), 4, 0, 0, 0, 0, 0, 0, 0]),
    'UnsupportedPackage',
  ),
  ('magic only', Uint8List.fromList(ascii.encode('Cr24')), 'Truncated'),
  (
    'crx3 header past the end',
    Uint8List.fromList([...ascii.encode('Cr24'), 3, 0, 0, 0, 0xff, 0, 0, 0]),
    'Truncated',
  ),
  ('a PDF', Uint8List.fromList(ascii.encode('%PDF-1.7')), 'NotAPackage'),
  ('nothing', Uint8List(0), 'NotAPackage'),
];

String _envelopeLabel(Envelope e) => switch (e) {
  ArchiveAt(:final format, :final offset) => '${format.name}@$offset',
  NoArchive(:final why) => why.runtimeType.toString(),
};

/// The rows [envelope] answers wrongly.
List<String> _envelopeMisses(Envelope Function(Uint8List) envelope) => [
  for (final (label, bytes, want) in _envelopeRows)
    if (_envelopeLabel(envelope(bytes)) != want) label,
];

/// The entry-name rows: each a path and the problem it has, or none.
const _nameRows = <(String, EntryProblem?)>[
  ('a.js', null),
  ('dir/a.js', null),
  ('_locales/en/messages.json', null),
  ('.well-known/x', null),
  ('/etc/passwd', EntryProblem.absolute),
  ('C:/x.js', EntryProblem.absolute),
  (r'a\b.js', EntryProblem.backslash),
  ('a\u0000.js', EntryProblem.controlCharacter),
  ('a\n.js', EntryProblem.controlCharacter),
  ('../x.js', EntryProblem.dotSegment),
  ('a/../../x.js', EntryProblem.dotSegment),
  ('./a.js', EntryProblem.dotSegment),
  ('..', EntryProblem.dotSegment),
  ('a//b.js', EntryProblem.emptySegment),
  ('', EntryProblem.emptySegment),
];

List<String> _nameMisses(EntryProblem? Function(String) problem) => [
  for (final (name, want) in _nameRows)
    if (problem(name) != want) name,
];

/// Planted mistake: a CRX3 header read with CRX2's layout, a key and a
/// signature length where version 3 has one header length.
Envelope _crx3ReadAsCrx2(Uint8List bytes) {
  final real = envelopeOf(bytes);
  if (real case ArchiveAt(format: PackageFormat.crx3)) {
    final d = ByteData.sublistView(bytes);
    final offset =
        16 + d.getUint32(8, Endian.little) + d.getUint32(12, Endian.little);
    return offset < bytes.length
        ? ArchiveAt(format: PackageFormat.crx3, offset: offset)
        : const NoArchive(Truncated());
  }
  return real;
}

/// Planted mistake: a `..` segment let through.
EntryProblem? _acceptsParent(String name) =>
    name.split('/').contains('..') ? null : entryNameProblem(name);

void main() {
  group('WEBEXT-013 a package is read from its bytes', () {
    test('a ZIP reads its files and what its manifest asks for', () {
      final package = _read(sampleZip());
      expect(package.format, PackageFormat.zip);
      expect(
        package.files.keys,
        unorderedEquals(['manifest.json', 'content.js']),
      );
      expect(
        utf8.decode(package.files['content.js']!),
        'document.title += "!";',
      );
      expect(package.manifest.name, 'Sample');
      expect(package.manifest.version, '1.0');
      expect(package.manifest.manifestVersion, 3);
      expect(package.signatureUnchecked, isFalse);
    });

    test('a CRX3 package is cut to the archive after its header', () {
      final package = _read(crx3Of(sampleZip()));
      expect(package.format, PackageFormat.crx3);
      expect(
        package.files.keys,
        unorderedEquals(['manifest.json', 'content.js']),
      );
      expect(package.signatureUnchecked, isTrue);
    });

    test('a CRX2 package is cut after its key and signature', () {
      final package = _read(crx2Of(sampleZip()));
      expect(package.format, PackageFormat.crx2);
      expect(package.manifest.name, 'Sample');
      expect(package.signatureUnchecked, isTrue);
    });

    test(
      'a signed Firefox package is a ZIP whose signature is not checked',
      () {
        final package = _read(
          zipOf([
            ZipEntryBytes('manifest.json', text: manifestJson()),
            ZipEntryBytes('META-INF/mozilla.rsa', text: 'signature'),
          ]),
        );
        expect(package.format, PackageFormat.zip);
        expect(package.signatureUnchecked, isTrue);
      },
    );

    test('stored entries read as deflated ones do', () {
      final package = _read(
        zipOf([
          ZipEntryBytes('manifest.json', text: manifestJson(), deflate: false),
          ZipEntryBytes('icons/', deflate: false),
          ZipEntryBytes('icons/16.png', text: 'png', deflate: false),
        ]),
      );
      expect(
        package.files.keys,
        unorderedEquals(['manifest.json', 'icons/16.png']),
      );
    });

    test('the archive is found where each envelope puts it', () {
      expect(_envelopeMisses(envelopeOf), isEmpty);
    });

    test('an entry name is a safe relative path or names its problem', () {
      expect(_nameMisses(entryNameProblem), isEmpty);
    });

    test('an entry that could land outside the folder refuses the package', () {
      ZipEntryBytes file(String name) => ZipEntryBytes(name, text: 'x');
      Uint8List withManifest(List<ZipEntryBytes> entries) => zipOf([
        ZipEntryBytes('manifest.json', text: manifestJson()),
        ...entries,
      ]);
      expect(
        _unsafe(withManifest([file('../evil.js')])),
        EntryProblem.dotSegment,
      );
      expect(_unsafe(withManifest([file('/abs.js')])), EntryProblem.absolute);
      expect(_unsafe(withManifest([file(r'a\b.js')])), EntryProblem.backslash);
      expect(
        _unsafe(
          withManifest([
            ZipEntryBytes('link', text: '/etc', externalAttributes: 0xa1ff0000),
          ]),
        ),
        EntryProblem.symlink,
      );
      expect(
        _unsafe(withManifest([file('A.js'), file('a.js')])),
        EntryProblem.duplicate,
      );
      expect(
        _unsafe(withManifest([file('a'), file('a/b.js')])),
        EntryProblem.duplicate,
      );
      expect(
        _unsafe(
          withManifest([
            ZipEntryBytes(
              'x',
              text: 'x',
              nameBytes: Uint8List.fromList([0xff, 0xfe]),
            ),
          ]),
        ),
        EntryProblem.notUtf8,
      );
    });

    test('a packaging feature the reader does not take is named', () {
      expect(
        _unsupported(
          zipOf([
            ZipEntryBytes('manifest.json', text: manifestJson(), flags: 1),
          ]),
        ),
        PackageFeature.encryption,
      );
      expect(
        _unsupported(
          zipOf([
            ZipEntryBytes('manifest.json', text: manifestJson(), method: 12),
          ]),
        ),
        PackageFeature.compressionMethod,
      );
      expect(
        _unsupported(_patchEnd(sampleZip(), offset: 4, value: 1)),
        PackageFeature.splitArchive,
      );
      expect(
        _unsupported(_patchEnd(sampleZip(), offset: 10, value: 0xffff)),
        PackageFeature.zip64,
      );
    });

    test('content that is not what the archive declares is corrupt', () {
      Uint8List one(ZipEntryBytes entry) =>
          zipOf([ZipEntryBytes('manifest.json', text: manifestJson()), entry]);
      expect(
        _refusal(one(ZipEntryBytes('a.js', text: 'abc', crc: 1))),
        isA<CorruptEntry>(),
      );
      expect(
        _refusal(one(ZipEntryBytes('a.js', text: 'abcdef', declaredSize: 3))),
        isA<CorruptEntry>(),
      );
      expect(
        _refusal(one(ZipEntryBytes('a.js', text: 'abc', declaredSize: 9))),
        isA<CorruptEntry>(),
      );
      expect(
        _refusal(
          one(
            ZipEntryBytes('a.js', text: 'abc', deflate: false, declaredSize: 2),
          ),
        ),
        isA<CorruptEntry>(),
      );
      expect(
        _refusal(
          one(
            ZipEntryBytes(
              'a.js',
              content: Uint8List.fromList(List.generate(64, (i) => i * 7)),
              deflate: false,
              method: 8,
            ),
          ),
        ),
        isA<CorruptEntry>(),
      );
    });

    /// The pure Dart inflater in `package:archive` 4.0.9 never returns on
    /// these 50 bytes; reading through it, this test would time out.
    test(
      'a deflate stream that loops a pure Dart inflater is refused',
      () {
        const hangs = [
          164,
          6,
          2,
          117,
          135,
          226,
          83,
          170,
          225,
          100,
          91,
          175,
          240,
          211,
          195, //
          127, 1, 105, 176, 204, 134, 67, 66, 248, 136, 229, 211, 68, 238, 171,
          242, 155, 114, 124, 1, 141, 115, 190, 202, 6, 136, 181, 131, 237, 196,
          228, 22, 87, 48, 252,
        ];
        expect(
          _refusal(
            zipOf([
              ZipEntryBytes('manifest.json', text: manifestJson()),
              ZipEntryBytes(
                'a.bin',
                content: Uint8List.fromList(hangs),
                deflate: false,
                method: 8,
                declaredSize: 4096,
              ),
            ]),
          ),
          isA<CorruptEntry>(),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('a deflate stream stops at the size its entry declares', () {
      final zeros = Uint8List(2 << 20);
      final bomb = zipOf([
        ZipEntryBytes('manifest.json', text: manifestJson()),
        ZipEntryBytes('bomb.bin', content: zeros, declaredSize: 1024),
      ]);
      expect(bomb.length, lessThan(zeros.length ~/ 100));
      expect(_refusal(bomb), isA<CorruptEntry>());
    });

    test(
      'sizes past the limit refuse the package before anything inflates',
      () {
        final huge = zipOf([
          ZipEntryBytes('manifest.json', text: manifestJson()),
          ZipEntryBytes('a.bin', text: 'x', declaredSize: 0xf0000000),
        ]);
        expect(_refusal(huge), isA<TooLarge>());
      },
    );

    test('a cut or inconsistent archive is refused', () {
      final zip = sampleZip();
      expect(
        _refusal(Uint8List.sublistView(zip, 0, zip.length - 10)),
        isA<Truncated>(),
      );
      final misplaced = Uint8List.fromList(zip);
      ByteData.sublistView(
        misplaced,
      ).setUint32(misplaced.length - 22 + 16, 3, Endian.little);
      expect(_refusal(misplaced), isA<BrokenArchive>());
    });

    test('a manifest that is not at the root, or not one, is named', () {
      expect(
        _refusal(
          zipOf([ZipEntryBytes('ext/manifest.json', text: manifestJson())]),
        ),
        isA<NoManifest>(),
      );
      expect(_manifestProblem('{'), ManifestProblem.notJson);
      expect(_manifestProblem('[]'), ManifestProblem.notObject);
      for (final version in [1, 4, '3', null]) {
        expect(
          _manifestProblem(
            jsonEncode({
              'manifest_version': version,
              'name': 'x',
              'version': '1',
            }),
          ),
          ManifestProblem.manifestVersion,
          reason: '$version',
        );
      }
      expect(
        _manifestProblem(jsonEncode({'manifest_version': 3, 'version': '1'})),
        ManifestProblem.noName,
      );
      expect(
        _manifestProblem(
          jsonEncode({'manifest_version': 3, 'name': ' ', 'version': '1'}),
        ),
        ManifestProblem.noName,
      );
      expect(
        _manifestProblem(jsonEncode({'manifest_version': 3, 'name': 'x'})),
        ManifestProblem.noVersion,
      );
    });

    test('a manifest with a byte order mark reads', () {
      final package = _read(
        zipOf([
          ZipEntryBytes(
            'manifest.json',
            content: Uint8List.fromList([
              0xef,
              0xbb,
              0xbf,
              ...utf8.encode(manifestJson()),
            ]),
          ),
        ]),
      );
      expect(package.manifest.name, 'Sample');
    });

    test('a localized name is read from the default locale', () {
      final manifest = {
        'manifest_version': 2,
        'name': '__MSG_extName__',
        'description': '__MSG_extDescription__ (beta)',
        'version': '1.0',
        'default_locale': 'en',
      };
      final read = _manifest(
        manifest,
        also: [
          ZipEntryBytes(
            '_locales/en/messages.json',
            text: jsonEncode({
              'ExtName': {'message': 'Tidy'},
              'extDescription': {'message': 'Hides clutter'},
            }),
          ),
        ],
      );
      expect(read.name, 'Tidy');
      expect(read.description, 'Hides clutter (beta)');
      expect(_manifest(manifest).name, '__MSG_extName__');
    });

    test('what a manifest asks for is split into permissions and hosts', () {
      final v2 = _manifest({
        'manifest_version': 2,
        'name': 'x',
        'version': '1',
        'permissions': [
          'storage',
          'tabs',
          '<all_urls>',
          'https://*.example.com/*',
          7,
        ],
        'optional_permissions': ['cookies'],
        'content_scripts': [
          {
            'matches': ['https://news.example/*'],
            'js': ['c.js'],
          },
          'not a map',
        ],
        'browser_action': {'default_popup': 'popup.html'},
        'options_ui': {'page': 'options.html'},
      });
      expect(v2.permissions, {'storage', 'tabs'});
      expect(v2.hosts, {
        '<all_urls>',
        'https://*.example.com/*',
        'https://news.example/*',
      });
      expect(v2.optional, {'cookies'});
      expect(v2.hasAction, isTrue);
      expect(v2.hasOptionsPage, isTrue);

      final v3 = _manifest({
        'manifest_version': 3,
        'name': 'x',
        'version': '1',
        'permissions': ['storage', 'scripting'],
        'host_permissions': ['*://*/*'],
        'optional_host_permissions': ['https://a.example/*'],
      });
      expect(v3.permissions, {'storage', 'scripting'});
      expect(v3.hosts, {'*://*/*'});
      expect(v3.optional, {'https://a.example/*'});
      expect(v3.hasAction, isFalse);
      expect(v3.hasOptionsPage, isFalse);
    });

    test('how the background runs is told from the manifest', () {
      ExtensionBackground background(int version, {Object? value}) =>
          _manifest({
            'manifest_version': version,
            'name': 'x',
            'version': '1',
            'background': ?value,
          }).background;
      expect(
        background(3, value: {'service_worker': 'sw.js'}),
        ExtensionBackground.serviceWorker,
      );
      expect(
        background(
          3,
          value: {
            'scripts': ['bg.js'],
          },
        ),
        ExtensionBackground.eventPage,
      );
      expect(
        background(
          2,
          value: {
            'scripts': ['bg.js'],
          },
        ),
        ExtensionBackground.persistentPage,
      );
      expect(
        background(2, value: {'page': 'bg.html', 'persistent': false}),
        ExtensionBackground.eventPage,
      );
      expect(background(2, value: null), ExtensionBackground.none);
      expect(background(3, value: 'bg.js'), ExtensionBackground.none);
    });

    /// Damaged copies of real packages and random bytes behind each magic:
    /// every one is read or refused, the same way twice. The seed is fixed
    /// and printed on a failure.
    test('random and damaged packages are read or refused, never thrown', () {
      final bases = [sampleZip(), crx3Of(sampleZip()), crx2Of(sampleZip())];
      for (var seed = 0; seed < 3000; seed++) {
        final random = Random(seed);
        final base = bases[seed % bases.length];
        final bytes = switch (seed % 4) {
          0 => Uint8List.fromList(
            base,
          )..[random.nextInt(base.length)] = random.nextInt(256),
          1 => Uint8List.sublistView(base, 0, random.nextInt(base.length)),
          2 => () {
            final copy = Uint8List.fromList(base);
            for (var i = 0; i < 8; i++) {
              copy[random.nextInt(copy.length)] = random.nextInt(256);
            }
            return copy;
          }(),
          _ => Uint8List.fromList([
            ...(random.nextBool() ? ascii.encode('Cr24') : [0x50, 0x4b, 3, 4]),
            ...List.generate(random.nextInt(400), (_) => random.nextInt(256)),
          ]),
        };
        expect(
          () => readExtensionPackage(bytes),
          returnsNormally,
          reason: 'seed $seed',
        );
        expect(
          readExtensionPackage(bytes).runtimeType,
          readExtensionPackage(bytes).runtimeType,
          reason: 'seed $seed',
        );
      }
    });
  });

  group('WEBEXT-013 planted mistakes are caught', () {
    test('a CRX3 header read as CRX2 misses a row', () {
      expect(_envelopeMisses(_crx3ReadAsCrx2), isNotEmpty);
    });

    test('a parent segment let through misses a row', () {
      expect(_nameMisses(_acceptsParent), isNotEmpty);
    });
  });
}
