import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/host_storage.dart'
    show bundledNotices, managedTorNotices;

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
/// package: the artwork and data files, the Rust crates in adblock-rust, the
/// Linux build's tor, and the libraries a Linux package bundles.
void registerLicenses() {
  // The pubspec asset glob pulls each `.txt` under `assets/licenses/` in.
  const customLicenses = <(List<String>, String)>[
    (['WebSpace Assets'], 'assets/LICENSE'),
    (['favicon (modified)'], 'assets/licenses/favicon.txt'),
    (['ClearURLs (rules data)'], 'assets/licenses/clearurls.txt'),
    (['Hagezi DNS Blocklists (domain data)'], 'assets/licenses/hagezi.txt'),
    (['EasyList filter lists (filter data)'], 'assets/licenses/easylist.txt'),
    (['AdGuard filters (filter data)'], 'assets/licenses/adguard.txt'),
    (['cdnjs (LocalCDN resource data)'], 'assets/licenses/cdnjs.txt'),
    (['OpenStreetMap (map data and tiles)'], 'assets/licenses/openstreetmap.txt'),
    (
      ['IPFire Location Database (Tor exit-country data)'],
      'assets/licenses/ipfire_location.txt'
    ),
    (['Kagi Bangs (site search list data)'], 'assets/licenses/kagi_bangs.txt'),
    (
      ['timezone-boundary-builder (time zone data)'],
      'assets/licenses/timezone_boundary_builder.txt'
    ),
    (
      ['Chrome UX Report top sites (address completion data)'],
      'assets/licenses/crux_top_lists.txt'
    ),
    (
      ['StevenBlack hosts, porn-only (domain data)'],
      'assets/licenses/stevenblack_hosts.txt'
    ),
    (
      ['uBlock Origin filter list index (backup import data)'],
      'assets/licenses/ubo_assets.txt'
    ),
    (
      ['Public Suffix List (compiled in through the psl crate)'],
      'assets/licenses/public_suffix_list.txt'
    ),
    // What pub packages compile in beside their own code, whose notices
    // Flutter's collection of each root LICENSE leaves out
    // (openspec/specs/legal/attributions.tsv).
    (['archive (the code it ported)'], 'assets/licenses/archive_other.txt'),
    (['image (the code it ported)'], 'assets/licenses/image_other.txt'),
    (['Unicode data (in characters)'], 'assets/licenses/unicode_data.txt'),
    (
      ['Bouncy Castle (in pointycastle)'],
      'assets/licenses/pointycastle_bouncycastle.txt'
    ),
    (['scrypt (in pointycastle)'], 'assets/licenses/pointycastle_scrypt.txt'),
    (['Apache httpd mime.types (in mime)'], 'assets/licenses/mime_httpd.txt'),
    (['FMDB (in sqflite_darwin)'], 'assets/licenses/fmdb.txt'),
    (['zxing-cpp (in flutter_zxing)'], 'assets/licenses/zxing_cpp.txt'),
    (['zint (in flutter_zxing)'], 'assets/licenses/zint.txt'),
    (
      ['nlohmann/json (in flutter_secure_storage_linux)'],
      'assets/licenses/nlohmann_json.txt'
    ),
    (
      ['Tor.framework (tor, libevent, OpenSSL, XZ Utils)'],
      'assets/licenses/tor_framework_components.txt'
    ),
  ];
  for (final (packages, assetPath) in customLicenses) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(assetPath);
      yield _PerLineLicenseEntry(packages, text: text);
    });
  }

  // The pods an Apple build links, from the acknowledgements its Podfile lays
  // out at pod install, and the Maven artifacts an Android build links, from
  // what android/app/maven_licences.gradle lists; each shown only on its own
  // platform, so one left from a build for another is not.
  LicenseRegistry.addLicense(() async* {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    if (defaultTargetPlatform == TargetPlatform.android && assets.contains(_mavenNotices)) {
      for (final (artifact, text) in mavenNotices(await rootBundle.loadString(_mavenNotices))) {
        yield _PerLineLicenseEntry(['$artifact (Maven)'], text: text);
      }
    }
    final apple = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    if (!apple || !assets.contains(_podNotices)) return;
    for (final (pod, text) in podNotices(await rootBundle.loadString(_podNotices))) {
      yield _PerLineLicenseEntry(['$pod (pod)'], text: text);
    }
  });

  // The Linux build's tor, its libraries and its lyrebird, from the notices
  // the build lays out beside it (linux/tor_build.sh, go/iptproxy/build.sh
  // lyrebird; TOR-027). Read where the build installed them; absent from
  // every other build.
  LicenseRegistry.addLicense(() async* {
    for (final (package, text) in await managedTorNotices()) {
      yield _PerLineLicenseEntry([package], text: text);
    }
  });

  // The libraries a snap or a flatpak bundles beside the app, WPE WebKit and
  // libwpe among them, which LGPL-2.1 asks the app's own notices to name.
  LicenseRegistry.addLicense(() async* {
    for (final (package, text) in await bundledNotices()) {
      yield _PerLineLicenseEntry([package], text: text);
    }
  });

  // Every crate the adblock library links and the redirect scripts it
  // serves, from the blob its build embeds (rust/webspace_adblock/build.rs).
  LicenseRegistry.addLicense(() async* {
    for (final dep in AdblockEngine.depLicenses()) {
      if (adblockNotice(dep) case (final package, final text)) {
        yield _PerLineLicenseEntry([package], text: text);
      }
    }
  });
}

/// One entry of the adblock library's blob as the licences page shows it: a
/// crate the library links, or the redirect scripts its build takes in, each
/// with its own licence files, which carry its copyright notices, or the
/// canonical SPDX text and its authors for one that ships none. Null for an
/// entry with no name.
(String, String)? adblockNotice(Map<String, dynamic> dep) {
  final name = dep['name'] as String? ?? '';
  if (name.isEmpty) return null;
  final version = dep['version'] as String? ?? '';
  final license = dep['license'] as String? ?? '<unspecified>';
  final repo = dep['repository'] as String? ?? '';
  final desc = dep['description'] as String? ?? '';
  final texts = (dep['license_texts'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final files = switch (dep['license_files']) {
    final List list => [
        for (final f in list)
          if (f case {'name': final String name, 'text': final String text})
            (name, text),
      ],
    _ => const <(String, String)>[],
  };
  final authors = switch (dep['authors']) {
    final List list => [
        for (final a in list)
          if (a case final String author) author,
      ],
    _ => const <String>[],
  };

  final parts = <String>[
    if (desc.isNotEmpty) desc,
    '',
    'Version: $version',
    'License: $license',
    if (files.isEmpty && authors.isNotEmpty) 'Authors: ${authors.join(', ')}',
    if (repo.isNotEmpty) 'Source: $repo',
    if (repo.isEmpty) 'Source: https://crates.io/crates/$name',
  ];
  if (files.isNotEmpty) {
    for (final (fileName, text) in files) {
      parts
        ..add('')
        ..add('--- $fileName ---')
        ..add('')
        ..add(text);
    }
  } else if (texts.isEmpty) {
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
  final package = switch (dep['kind']) {
    'redirect-resources' => '$name (redirect scripts the content blocker serves)',
    _ => '$name (Rust crate, transitive via adblock-rust)',
  };
  return (package, parts.join('\n'));
}

const String _podNotices = 'assets/native_notices/pods.md';
const String _mavenNotices = 'assets/native_notices/maven.json';

/// Each Maven artifact and the licences its POM names, from what
/// android/app/maven_licences.gradle writes; an entry of the wrong shape
/// reads as absent.
List<(String, String)> mavenNotices(String json) => [
      if (jsonDecode(json) case final List entries)
        for (final entry in entries)
          if (entry
              case {
                'group': final String group,
                'artifact': final String artifact,
                'version': final String version,
                'licences': final List licences,
              })
            (
              '$group:$artifact',
              [
                'Version: $version',
                for (final licence in licences)
                  if (licence case {'name': final String name, 'url': final String url})
                    url.isEmpty ? 'License: $name' : 'License: $name ($url)',
              ].join('\n'),
            ),
    ];

/// Each pod and its licence from the acknowledgements CocoaPods writes
/// (`Pods-Runner-acknowledgements.markdown`): a `## <pod>` heading, then its
/// licence, up to the next heading or CocoaPods' closing line.
List<(String, String)> podNotices(String markdown) {
  final out = <(String, String)>[];
  String? pod;
  final text = StringBuffer();
  void close() {
    if (pod case final name?) out.add((name, text.toString().trim()));
    text.clear();
  }

  for (final line in const LineSplitter().convert(markdown)) {
    if (line.startsWith('## ')) {
      close();
      pod = line.substring(3).trim();
    } else if (line.startsWith('Generated by CocoaPods')) {
      close();
      pod = null;
    } else if (pod != null) {
      text.writeln(line);
    }
  }
  close();
  return out;
}
