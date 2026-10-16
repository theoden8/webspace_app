// The models lib/formal_model/main.dart prints for formal/, held to what the
// code declares: every step with its outcomes and the jar's places once
// each. formal/verify.sh runs the printer and the checkers on what it writes.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/activation_place.dart';
import 'package:webspace/controllers/activation_table.dart';
import 'package:webspace/formal_model/checks.dart';
import 'package:webspace/formal_model/models.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/step_table.dart';

void main() {
  final printed = {for (final f in printedModels()) f.path: f.text};

  test('every step prints with its outcomes', () {
    for (final s in ActivationStep.values) {
      expect(
        printed['activation_steps.tla'],
        contains('    ${s.action} |-> {'),
      );
    }
  });

  test(
    'the jar\'s tables share no place name, so Inv_Places reads each once',
    () {
      final unload = {for (final s in tables.jar.steps) s.place.name};
      final restore = {for (final s in tables.restore.steps) s.place.name};
      expect(unload.intersection(restore), isEmpty);
    },
  );

  test(
    'the jar\'s step tables print as the model\'s actions and their proof cases',
    () {
      for (final t in [
        tables.activation,
        tables.unload,
        tables.jar,
        tables.restore,
      ]) {
        for (final (:step, place: _) in t.steps) {
          // A spawned input lands only in its spawner's turn, so it is no
          // action of its own (WEBSPACE-013's keep, once a guardless one).
          if (step.spawned) {
            expect(
              printed['activation_tables.tla'],
              isNot(contains('${step.action}(f) ==')),
            );
            expect(
              printed['activation_steps.tla'],
              matches(RegExp('Spawned_Inputs == \\{[^}]*"${step.action}"')),
            );
            continue;
          }
          expect(
            printed['activation_tables.tla'],
            contains('${step.action}(f) =='),
          );
          expect(
            printed['activation_tables.tla'],
            contains('    \\/ ${step.action}(f)'),
          );
          expect(
            printed['activation_tables_proof.tla'],
            contains('CASE ${step.action}(f)'),
          );
        }
      }
    },
  );

  test('the unload flow nests the jar\'s places and no other', () {
    final nested = {
      for (final p in UnloadPlace.values)
        if (tables.unload.at(p) is Within) p,
    };
    expect(nested, {for (final s in tables.jar.steps) s.place});
  });

  test('the activation nests the unload flow\'s and the restore\'s places', () {
    final nested = {
      for (final p in ActivationPlace.values)
        if (tables.activation.at(p) is Within) p.name,
    };
    expect(nested, {
      for (final s in tables.unload.steps) s.place.name,
      for (final p in UnloadPlace.values)
        if (tables.unload.at(p) is Within) p.name,
      for (final s in tables.restore.steps) s.place.name,
    });
    // Each nested table leaves by a place of the activation's.
    for (final p in [...UnloadPlace.values, ...RestorePlace.values]) {
      expect(ActivationPlace.values.map((a) => a.name), contains(p.name));
    }
  });

  test('a planted mistake changes exactly one action or definition', () {
    for (final Mutant(:name) in Mutant.values) {
      var changed = 0;
      for (final module in ['activation_tables.tla', 'activation_ops.tla']) {
        final real = printed[module]!.split('\n\n').toSet();
        final mutant = printed['mutants/$name/$module']!.split('\n\n').toSet();
        changed += mutant.difference(real).length;
      }
      expect(
        changed,
        1,
        reason: 'mutant $name should differ from the modules in one place',
      );
    }
  });

  test('each planted mistake prints beside the modules it may change', () {
    for (final Mutant(:name) in Mutant.values) {
      expect(printed, contains('mutants/$name/activation_tables.tla'));
      expect(printed, contains('mutants/$name/activation_ops.tla'));
    }
  });

  // Rung 5: the invariants and witnesses are hand-written TLA+, which no
  // Dart type sees; this holds the enums to the definitions they name.
  test('every invariant and witness activation.tla states is checked', () {
    final tla = File('formal/activation.tla').readAsStringSync();
    final stated = {
      for (final m in RegExp(r'^((?:Inv|Reach)_\w+) ==', multiLine: true)
          .allMatches(tla))
        m[1]!,
    };
    final checked = {
      for (final i in Inv.values)
        if (i != Inv.typeOK && i != Inv.places) i.tla,
      for (final w in Witness.values) w.tla,
    };
    expect(checked, stated);
    for (final i in Inv.values) {
      expect(
        ActivationWorld.values.any((w) => w.invariants.contains(i)),
        isTrue,
        reason: '${i.tla} holds in no world',
      );
    }
  });

  test('each check prints its own config, each planted mistake caught', () {
    final checks = allChecks;
    final rows = printed['checks.tsv']!.trimRight().split('\n');
    expect(rows, hasLength(checks.length));
    for (final c in checks) {
      expect(printed['checks/${c.cfg}.cfg'], c.text);
    }
    expect({for (final c in checks) c.mutant}, containsAll(Mutant.values));
  });

  test('the activation\'s staleness prints from the flow and the version', () {
    expect(
      ActivationTable.stale.tla,
      'Stale(f) == (((fl[f].kind = "tap") \\/ (fl[f].kind = "nested")) '
      '\\/ (fl[f].kind = "space")) /\\ (fl[f].v # version)',
    );
  });

  test('every definition prints once, from the engine that owns it', () {
    final ops = printed['activation_ops.tla']!;
    for (final d in definitions) {
      expect(ops, contains('\n${d.tla}\n'));
    }
    final names = [for (final d in definitions) d.name];
    expect(names.toSet().length, names.length);
  });
}
