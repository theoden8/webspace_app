import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/services/adblock_engine.dart';

/// LicenseEntry that emits one [LicenseParagraph] per source line,
/// so structural single line breaks (license titles, numbered
/// section headers, template lines) survive the renderer.
///
/// `LicenseEntryWithLineBreaks` only breaks on blank lines and
/// folds every other `\n` into a space, which collapses Apache-2.0
/// title blocks and similar multi-line headers into one wrapping
/// paragraph. The license texts the `license` Rust crate emits
/// (and the bundled assets/licenses/*.txt files) all use single
/// `\n` for structural breaks AND keep paragraph bodies as single
/// long lines, so per-line preservation renders correctly without
/// hurting paragraph flow.
class _PerLineLicenseEntry extends LicenseEntry {
  _PerLineLicenseEntry(this.packages, {required String text}) : _text = text;

  @override
  final Iterable<String> packages;
  final String _text;

  @override
  Iterable<LicenseParagraph> get paragraphs sync* {
    for (final line in const LineSplitter().convert(_text)) {
      var leading = 0;
      while (leading < line.length && line[leading] == ' ') {
        leading++;
      }
      // LicenseParagraph indents are integer levels (0..8 roughly);
      // map every 2 leading spaces to one indent step so indented
      // numbered items / template snippets still look indented.
      final indent = (leading ~/ 2).clamp(0, 8);
      yield LicenseParagraph(line.substring(leading), indent);
    }
  }
}

/// Registers the licences of everything the app bundles that is not a Dart
/// package: the artwork and data files, and the Rust crates in adblock-rust.
void registerLicenses() {
  // The pubspec asset glob pulls each `.txt` under `assets/licenses/` in.
  const customLicenses = <(List<String>, String)>[
    (['WebSpace Assets'], 'assets/LICENSE'),
    (['favicon (modified)'], 'assets/licenses/favicon.txt'),
    (['ClearURLs (rules data)'], 'assets/licenses/clearurls.txt'),
    (['Hagezi DNS Blocklists (domain data)'], 'assets/licenses/hagezi.txt'),
    (['EasyList filter lists (filter data)'], 'assets/licenses/easylist.txt'),
    (
      // uBO ships the redirect-resource bodies (noop.js, 1x1.gif,
      // neutered trackers, etc.) we embed at build time. uBO isn't
      // a Rust crate so the transitive-deps SPDX extractor below
      // can't reach it — the bundled file carries the MPL-2.0 text
      // for that contribution. The `adblock` and `webspace_adblock`
      // crates themselves flow through the transitive enumeration
      // with canonical SPDX text from the `license` crate.
      ['uBlock Origin web-accessible resources (redirect bodies)'],
      'assets/licenses/ubo_resources.txt'
    ),
    (['cdnjs (LocalCDN resource data)'], 'assets/licenses/cdnjs.txt'),
    (['OpenStreetMap (map data and tiles)'], 'assets/licenses/openstreetmap.txt'),
    (
      ['IPFire Location Database (Tor exit-country data)'],
      'assets/licenses/ipfire_location.txt'
    ),
    (['Kagi Bangs (site search list data)'], 'assets/licenses/kagi_bangs.txt'),
  ];
  for (final (packages, assetPath) in customLicenses) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(assetPath);
      yield _PerLineLicenseEntry(packages, text: text);
    });
  }

  // Transitive Rust dependency attribution. Loaded from the
  // adblock_rust shared library's static metadata blob (see
  // rust/webspace_adblock/build.rs). Surfaces every crate
  // adblock-rust pulls in (regex, serde, flatbuffers, idna, …) with
  // its SPDX license + canonical SPDX text (sourced at build time
  // via the `license` crate's vendored license-list-data, NOT
  // hand-typed). Dual-licensed crates ship every relevant text.
  LicenseRegistry.addLicense(() async* {
    for (final dep in AdblockEngine.depLicenses()) {
      final name = dep['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final version = dep['version'] as String? ?? '';
      final license = dep['license'] as String? ?? '<unspecified>';
      final repo = dep['repository'] as String? ?? '';
      final desc = dep['description'] as String? ?? '';
      final texts = (dep['license_texts'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

      final parts = <String>[
        if (desc.isNotEmpty) desc,
        '',
        'Version: $version',
        'License: $license',
        if (repo.isNotEmpty) 'Source: $repo',
        if (repo.isEmpty) 'Source: https://crates.io/crates/$name',
      ];
      if (texts.isEmpty) {
        parts.add('');
        parts.add(
            'Canonical SPDX license text was not resolvable for "$license". '
            'See the upstream source above for the original.');
      } else {
        for (final lt in texts) {
          final id = lt['id'] as String? ?? '';
          final lname = lt['name'] as String? ?? id;
          final text = lt['text'] as String? ?? '';
          if (text.isEmpty) continue;
          parts.add('');
          parts.add('--- $lname (SPDX: $id) ---');
          parts.add('');
          parts.add(text);
        }
      }
      yield _PerLineLicenseEntry(
        ['$name (Rust crate, transitive via adblock-rust)'],
        text: parts.join('\n'),
      );
    }
  });
}
