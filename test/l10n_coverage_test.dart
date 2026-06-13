import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards localization coverage (LOC-003). The English ARB is the source of
/// truth; every other locale MUST define the same keys with the same
/// placeholders and no empty values, so a half-translated locale can never
/// ship a blank or mismatched-interpolation string.
void main() {
  const arbDir = 'lib/l10n';
  const templateName = 'app_en.arb';

  final template = _loadArb('$arbDir/$templateName');
  final templateKeys = _messageKeys(template);
  final templatePlaceholders = {
    for (final k in templateKeys) k: _placeholderTokens(template[k] as String),
  };

  test('template ARB is well-formed and fully documented', () {
    expect(templateKeys, isNotEmpty);
    for (final k in templateKeys) {
      expect(
        (template[k] as String).trim(),
        isNotEmpty,
        reason: 'Template key "$k" has an empty value.',
      );
      final meta = template['@$k'];
      expect(
        meta,
        isA<Map>(),
        reason: 'Template key "$k" is missing its "@$k" metadata block.',
      );
      expect(
        (meta as Map)['description'],
        isA<String>(),
        reason: 'Template key "$k" is missing a description.',
      );
    }
  });

  final localeFiles = Directory(arbDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.arb') && !f.path.endsWith(templateName))
      .toList();

  for (final file in localeFiles) {
    final name = file.uri.pathSegments.last;
    test('$name has full key + placeholder parity with the template', () {
      final arb = _loadArb(file.path);
      final keys = _messageKeys(arb);

      expect(
        keys.difference(templateKeys),
        isEmpty,
        reason: '$name defines keys absent from the template.',
      );
      expect(
        templateKeys.difference(keys),
        isEmpty,
        reason: '$name is missing keys. Translate them from app_en.arb and '
            'add them.',
      );
      for (final k in keys) {
        expect(
          (arb[k] as String).trim(),
          isNotEmpty,
          reason: '$name key "$k" is empty.',
        );
        expect(
          _placeholderTokens(arb[k] as String),
          templatePlaceholders[k],
          reason: '$name key "$k" has placeholders that differ from the '
              'template; interpolation would break.',
        );
      }
    });
  }

  test('no key is left as the English source across every locale', () {
    // Key/placeholder parity (above) cannot tell a real translation from an
    // English value copied verbatim into every locale to satisfy parity. A
    // string identical to the template in ALL locales was almost certainly
    // never translated. Coincidental matches in only SOME locales (a genuine
    // translation that happens to equal English, e.g. "OK", "URL") are fine
    // and stay below this threshold, so they are not flagged.
    //
    // The allowlist (_identicalEverywhereAllowlist) holds strings that are
    // legitimately identical in every locale: brand/product names, acronyms,
    // example hosts, and universal tokens. Add to it only when a value is
    // genuinely untranslatable.
    final locales = [
      for (final f in localeFiles) _loadArb(f.path),
    ];
    final offenders = <String>[];
    for (final k in templateKeys) {
      if (_identicalEverywhereAllowlist.contains(k)) continue;
      final tv = template[k] as String;
      final identicalEverywhere = locales.every((arb) => arb[k] == tv);
      if (identicalEverywhere) offenders.add(k);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'These keys are the English source in every locale (never '
          'translated): $offenders. Translate them in each app_<x>.arb, or '
          'if a value is genuinely universal (brand, acronym, example) add '
          'its key to the allowlist in this test.',
    );
  });

  test('every allowlisted key is actually identical across all locales', () {
    // Keeps the allowlist honest: once a key is translated everywhere it no
    // longer needs an exemption, so a stale entry should be removed.
    final locales = [
      for (final f in localeFiles) _loadArb(f.path),
    ];
    final stale = <String>[];
    for (final k in _identicalEverywhereAllowlist) {
      if (!templateKeys.contains(k)) {
        stale.add('$k (absent from template)');
        continue;
      }
      final tv = template[k] as String;
      if (!locales.every((arb) => arb[k] == tv)) stale.add(k);
    }
    expect(
      stale,
      isEmpty,
      reason: 'Allowlisted keys that are no longer English-in-every-locale '
          '(remove them from the allowlist): $stale',
    );
  });

  test('gen-l10n reported zero untranslated messages', () {
    final report = File('l10n_untranslated.json');
    if (!report.existsSync()) return; // regenerated on build; absent in isolation
    final decoded = jsonDecode(report.readAsStringSync());
    expect(
      decoded,
      isEmpty,
      reason: 'gen-l10n flagged untranslated messages: $decoded',
    );
  });
}

/// Keys whose value is legitimately identical in every locale (brand/product
/// names, acronyms, example hosts, universal tokens), so they are exempt from
/// the "never translated across every locale" guard.
const _identicalEverywhereAllowlist = <String>{
  'appTitle', // WebSpace (product name)
  'appSettingsLocalCdn', // LocalCDN (product name)
  'siteSettingsLocalCdn', // LocalCDN
  'siteSettingsClearUrls', // ClearURLs (product name)
  'devToolsTabAbp', // ABP (acronym)
  'devToolsTabDns', // DNS (acronym)
  'siteSettingsLocationProviderGps', // GPS (acronym)
  'siteSettingsLocationProviderGsm', // GSM (acronym)
  'siteSettingsUserAgent', // User-Agent (HTTP header name)
  'trustedCertFingerprintLabel', // SHA-256 (acronym)
  'untrustedCertSha256', // SHA-256
  'linkHandlingHostnameHint', // example.com (example host)
  'linkHandlingTestUrlHint', // https://example.org/foo (example URL)
  'siteSettingsLetterboxAutoHint', // "auto" (universal token)
};

Map<String, dynamic> _loadArb(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  return (decoded as Map).cast<String, dynamic>();
}

Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// Variable names referenced by an ICU message string: the identifier of every
/// `{name}` interpolation and the control variable of `{count, plural, ...}` /
/// `{sel, select, ...}`. The trailing `[,}]` guard skips literal text inside
/// plural/select branches (e.g. `{Copied ...}`), so translated branches whose
/// wording differs do not register as placeholder drift.
Set<String> _placeholderTokens(String value) => RegExp(r'\{(\w+)\s*[,}]')
    .allMatches(value)
    .map((m) => m.group(1)!)
    .toSet();
