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
    // Nor through mint: it is library-private, so only DownloadsService.start
    // mints an id. Without this, DL-008's "reachable to a handler only through
    // pageTask" would rest on the token's unguessability, not on the type.
    const mint = "${preamble}final x = "
        'DownloadTaskId.mint(serial: 1, view: null);';
    expect(await errorsIn(held), isEmpty);
    expect(await errorsIn(raw), contains('argument_type_not_assignable'));
    expect(await errorsIn(forge), isNotEmpty,
        reason: 'DownloadTaskId has no public constructor');
    expect(await errorsIn(mint), isNotEmpty, reason: 'mint is library-private');

    // Planted mistake: a public mint lets any code make an id, reopening the
    // hole — under it the probe compiles.
    const owner = 'lib/services/download_manager.dart';
    final source = File(owner).readAsStringSync();
    final publicMint = source
        .replaceFirst(
            'factory DownloadTaskId._mint(', 'factory DownloadTaskId.mint(')
        .replaceFirst(
            'id: DownloadTaskId._mint(', 'id: DownloadTaskId.mint(');
    expect(publicMint, isNot(source), reason: 'the planted mistake must apply');
    expect(await errorsIn(mint, overlays: {owner: publicMint}), isEmpty,
        reason: 'with a public mint any code could make an id');
  }, timeout: _probe);
  test('ARCH-016: an archive\'s sites join the lists only through an admission',
      () async {
    const preamble = "import 'package:webspace/controllers/site_set_change.dart';\n"
        "import 'package:webspace/services/archive_ids.dart';\n"
        "import 'package:webspace/web_view_model.dart';\n";
    // Admitted against the listed ids, the sites join.
    const admitted = '${preamble}ArchiveOpened f(Set<String> listed) => '
        'ArchiveOpened(sites: Admitted.of(const [], listed: {}, '
        'build: (r) => WebViewModel.fromJson(r, stateSetterF: null)), '
        'webspaces: const [], appTierMembership: const {}, rebuilt: (_) {});';
    // A list of models carries no admission: an archived site could join
    // under an id a listed site holds.
    const raw = '${preamble}ArchiveOpened f(List<WebViewModel> sites) => '
        'ArchiveOpened(sites: sites, webspaces: const [], '
        'appTierMembership: const {}, rebuilt: (_) {});';
    // Nor can one be made by hand around them.
    const forged = '${preamble}Admitted<WebViewModel> f(List<WebViewModel> s, '
        'ArchiveIds ids) => Admitted._(s, ids: ids, records: const [], '
        'runsAs: const [], build: (_) => s.first);';
    expect(await errorsIn(admitted), isEmpty);
    expect(await errorsIn(raw), contains('argument_type_not_assignable'));
    expect(await errorsIn(forged), isNotEmpty,
        reason: 'Admitted has no public constructor');

    // Planted mistake: ArchiveOpened takes a plain list again, and the raw
    // probe compiles.
    const owner = 'lib/controllers/site_set_change.dart';
    final source = File(owner).readAsStringSync();
    final plain = source.replaceFirst(
        'final Admitted<WebViewModel> sites;', 'final List<WebViewModel> sites;');
    expect(plain, isNot(source), reason: 'the planted mistake must apply');
    expect(await errorsIn(raw, overlays: {owner: plain}), isEmpty,
        reason: 'with a plain list any caller could join unadmitted sites');
  }, timeout: _probe);
}
