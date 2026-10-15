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

  test('the README names EasyList and adblock-rust (CB-007)', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('EasyList'));
    expect(readme, contains('adblock-rust'));
  });
}
