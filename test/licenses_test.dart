import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/licenses.dart';

/// The data files the app ships carry their licences into the app's licence
/// page, read from the bundled text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LicenseRegistry.reset();
    registerLicenses();
  });
  tearDown(LicenseRegistry.reset);

  // The first entries are the bundled files; the Rust crates' come last and
  // need the native library, so each search stops before them.
  Future<String> licenceOf(String package) async {
    final entry = await LicenseRegistry.licenses
        .firstWhere((e) => e.packages.contains(package));
    return entry.paragraphs.map((p) => p.text).join('\n');
  }

  for (final (package, licence, id) in [
    ('ClearURLs (rules data)', 'GNU Lesser General Public License v3.0', 'CURL-011'),
    ('Hagezi DNS Blocklists (domain data)', 'GNU General Public License v3.0', 'DNS-009'),
    ('EasyList filter lists (filter data)', 'CC BY-SA 3.0', 'CB-007'),
  ]) {
    test('$package is listed under its licence ($id)', () async {
      expect(await licenceOf(package), contains(licence));
    });
  }

  test('EasyList is credited to its authors (CB-007)', () async {
    expect(await licenceOf('EasyList filter lists (filter data)'),
        contains('The EasyList authors'));
  });

  // Every text under assets/licenses is a component that neither pub's nor
  // Cargo's collector reaches, so one left unregistered never shows.
  test('every licence text the app bundles is on the licences page (LICENSE-003)', () async {
    String lines(Iterable<String> all) =>
        all.map((l) => l.trimLeft()).where((l) => l.isNotEmpty).join('\n');
    final wanted = {
      for (final f in Directory('assets/licenses').listSync().whereType<File>())
        if (f.path.endsWith('.txt')) f.path: lines(f.readAsLinesSync()),
    };
    expect(wanted, isNotEmpty);
    await for (final entry in LicenseRegistry.licenses) {
      final text = lines(entry.paragraphs.map((p) => p.text));
      wanted.removeWhere((_, file) => file == text);
      if (wanted.isEmpty) break;
    }
    expect(wanted.keys, isEmpty, reason: 'registered in lib/services/licenses.dart');
  });

  test('the README names EasyList and adblock-rust (CB-007)', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('EasyList'));
    expect(readme, contains('adblock-rust'));
  });
}
