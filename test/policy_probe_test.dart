// The access policy's rules that a type holds (docs/security/policy.md): each
// test resolves a probe the compiler must reject, beside a control it must
// accept, and the planted mistake that would reopen the hole, under which the
// probe compiles. Rung 1; spec_map counts each requirement named here as
// proved by type.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/compile_probe.dart';

const _probe = Timeout(Duration(minutes: 2));

void main() {
  test('BACKUP-016: live state is reached only through a planSettingsImport plan',
      () async {
    const owner = 'lib/settings_import_engine.dart';
    const make = '''
import 'package:webspace/settings_import_engine.dart';
final make = SettingsImportPlan.new;
''';
    const control = '''
import 'package:webspace/settings_import_engine.dart';
final make = planSettingsImport;
''';
    expect(await errorsIn(control), isEmpty);
    expect(await errorsIn(make), isNotEmpty);

    final source = File(owner).readAsStringSync();
    final public = source
        .replaceFirst('const SettingsImportPlan._({', 'const SettingsImportPlan({')
        .replaceFirst('return SettingsImportPlan._(', 'return SettingsImportPlan(');
    expect(public, isNot(source), reason: 'the planted mistake must apply');
    expect(await errorsIn(make, overlays: {owner: public}), isEmpty,
        reason: 'with a public constructor any code could build a plan');
  }, timeout: _probe);
}
