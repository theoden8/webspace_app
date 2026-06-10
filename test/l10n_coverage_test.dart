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
        reason: '$name is missing keys. Run the fill script '
            '(tool/translate_arb.dart) to populate them.',
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
