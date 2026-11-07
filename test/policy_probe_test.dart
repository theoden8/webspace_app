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
  test('DL-008: a page cannot name a download task from a raw string',
      () async {
    const preamble =
        "import 'package:webspace/services/download_manager.dart';\n";
    // A handler holding a real id may mutate its task.
    const held = "${preamble}void f(DownloadTaskId id) => "
        "DownloadsService.instance.fail(id, message: 'x');";
    // A raw token string the page sent cannot: the method takes a
    // DownloadTaskId, which has no public constructor to forge one.
    const raw = "${preamble}void f() => "
        "DownloadsService.instance.fail('dl-1-0123456789abcdef', message: 'x');";
    const forge = "${preamble}final x = DownloadTaskId('dl-1-0123456789abcdef');";
    expect(await errorsIn(held), isEmpty);
    expect(await errorsIn(raw), contains('argument_type_not_assignable'));
    expect(await errorsIn(forge), isNotEmpty,
        reason: 'DownloadTaskId has no public constructor');
  }, timeout: _probe);
}
