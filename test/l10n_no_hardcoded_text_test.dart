import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the localization invariant LOC-002: a migrated UI file must never
/// pass a raw string literal into a user-facing display sink. Every string
/// the user can read goes through `AppLocalizations` (an ARB key), so there
/// is no unkeyed text on screen.
///
/// The migration is phased (see openspec/specs/localization/spec.md): the
/// `migrated` list is enforced and only grows; `pending` files are known to
/// still contain hardcoded strings and are exempt until migrated. Every UI
/// file under the scanned roots MUST appear in exactly one list, so a newly
/// added screen can't slip past the guard unclassified.
void main() {
  // Enforced: zero hardcoded user-facing literals. Move files here as they
  // are migrated. This list only grows.
  const migrated = <String>{
    'lib/main.dart',
    'lib/screens/add_site.dart',
    'lib/screens/app_settings.dart',
    'lib/screens/dev_tools.dart',
    'lib/screens/inappbrowser.dart',
    'lib/screens/link_handling_settings.dart',
    'lib/screens/location_picker.dart',
    'lib/screens/settings.dart',
    'lib/screens/site_settings_qr.dart',
    'lib/screens/site_settings_qr_scanner.dart',
    'lib/screens/trusted_certificates.dart',
    'lib/screens/user_scripts.dart',
    'lib/screens/webspace_detail.dart',
    'lib/screens/webspaces_list.dart',
    'lib/widgets/download_button.dart',
    'lib/widgets/external_url_prompt.dart',
    'lib/widgets/find_toolbar.dart',
    'lib/widgets/hint_button.dart',
    'lib/widgets/root_messenger.dart',
    'lib/widgets/stats_banner.dart',
    'lib/widgets/untrusted_cert_prompt.dart',
    'lib/widgets/url_bar.dart',
  };

  // Known not-yet-migrated. Allowed to contain hardcoded strings for now.
  // Shrinks as files move to `migrated`; the goal is an empty set.
  const pending = <String>{};

  // Roots scanned for user-facing widgets. Service/model files render no UI.
  const scanRoots = <String>['lib/main.dart', 'lib/screens', 'lib/widgets'];

  test('every scanned UI file is classified as migrated or pending', () {
    final discovered = _discoverDartFiles(scanRoots);
    final classified = {...migrated, ...pending};

    final unclassified = discovered.difference(classified);
    expect(
      unclassified,
      isEmpty,
      reason:
          'New UI file(s) are not classified. Add each to `migrated` (after '
          'routing every string through AppLocalizations) or `pending` in '
          'test/l10n_no_hardcoded_text_test.dart:\n  ${unclassified.join('\n  ')}',
    );

    final stale = classified.difference(discovered);
    expect(
      stale,
      isEmpty,
      reason: 'Classified file(s) no longer exist; drop them from the lists:\n'
          '  ${stale.join('\n  ')}',
    );

    expect(
      migrated.intersection(pending),
      isEmpty,
      reason: 'A file is listed as both migrated and pending.',
    );
  });

  test('migrated files contain no hardcoded user-facing text', () {
    final violations = <String>[];
    for (final rel in migrated) {
      final file = File(rel);
      expect(file.existsSync(), isTrue, reason: 'Missing migrated file: $rel');
      violations.addAll(_findHardcodedDisplayText(rel, file.readAsStringSync()));
    }
    expect(
      violations,
      isEmpty,
      reason: 'Hardcoded user-facing string(s) found in migrated files. Route '
          'each through AppLocalizations (an ARB key); extract pure-data '
          'strings to a local variable before passing to a display widget:\n'
          '${violations.join('\n')}',
    );
  });
}

Set<String> _discoverDartFiles(List<String> roots) {
  final out = <String>{};
  for (final root in roots) {
    final entity = FileSystemEntity.typeSync(root);
    if (entity == FileSystemEntityType.file) {
      if (root.endsWith('.dart')) out.add(root);
    } else if (entity == FileSystemEntityType.directory) {
      for (final f in Directory(root).listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) {
          out.add(f.path.replaceAll('\\', '/'));
        }
      }
    }
  }
  return out;
}

/// Display sinks that put a string directly on screen. A quoted literal
/// opening immediately inside any of these is unkeyed text.
final _sinkPatterns = <RegExp>[
  // Text('...'), const Text("..."), SelectableText('...'), Tooltip('...').
  RegExp(r'''\b(?:Text|SelectableText|Tooltip)\(\s*(?:const\s+)?['"]'''),
  // Named display/label/decoration properties: tooltip: '...', hintText: "...".
  RegExp(
    r'''\b(?:tooltip|hintText|labelText|helperText|errorText|counterText'''
    r'''|prefixText|suffixText|semanticLabel)\s*:\s*['"]''',
  ),
];

List<String> _findHardcodedDisplayText(String rel, String source) {
  final stripped = _stripComments(source);
  final hits = <String>[];
  for (final p in _sinkPatterns) {
    for (final m in p.allMatches(stripped)) {
      final line = '\n'.allMatches(stripped.substring(0, m.start)).length + 1;
      final end = m.start + 60 < stripped.length ? m.start + 60 : stripped.length;
      final snippet = stripped.substring(m.start, end).split('\n').first.trim();
      hits.add('  $rel:$line: $snippet');
    }
  }
  hits.sort();
  return hits;
}

String _stripComments(String source) {
  // Remove block comments, then line comments. Good enough for the migrated
  // files, which are the only inputs; avoids a heavyweight analyzer dependency.
  final noBlock = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return noBlock
      .split('\n')
      .map((l) {
        final idx = l.indexOf('//');
        return idx >= 0 ? l.substring(0, idx) : l;
      })
      .join('\n');
}
