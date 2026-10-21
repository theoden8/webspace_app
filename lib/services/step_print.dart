import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';

/// One alternative of a printed action, marking an exposed unconditional spawn.
typedef StepAlternative = ({String tla, bool spawns});

/// The program counter can reject a step before TLC scans every flow for Calm.
enum TlaGuardOrder {
  declared,
  pcFirst;

  static const preferred = pcFirst;

  List<String> arrange(List<String> guards) => switch (this) {
    pcFirst when guards.length >= 2 && guards[0] == 'Calm' &&
        guards[1].startsWith('fl[f].pc = ') => [
      ...guards.take(2).toList().reversed,
      ...guards.skip(2),
    ],
    declared || pcFirst => guards,
  };
}

typedef _ActionContext<P extends Enum> = ({
  List<ModelVar> variables,
  Set<P> ending,
  bool awaited,
  Map<String, List<Assign<Object?>>> entered,
  Map<ActivationStep, Step<Object?, Enum>> starts,
  TlaGuardOrder guardOrder,
});

/// What a step table is in the model, beside how it runs: what each place
/// needs, what a flow records on entering a place, each step's footprint
/// and its TLA+ action, all read off the declarations the runner runs.
extension TablePrint<W, P extends Enum> on StepTable<W, P> {
  /// Each place's need as a conjunct of `Inv_Places`, with the flow as `f`.
  List<String> get placesTla => [
    for (final (:place, :step) in steps)
      if (step.holds case final h?)
        '(fl[f].pc = "${place.name}" => (${h.tla}))',
  ];

  /// What the flow records as it reaches each place whose call reads at
  /// its start ([Call.reads]), by place name: printed on every arm that
  /// enters the place, in this table or another's.
  Map<String, List<Assign<W>>> get readsByPlace => {
    for (final (:place, :step) in steps)
      if (step.call case Call(:final reads) when reads.isNotEmpty)
        place.name: reads,
  };

  /// What each step's notes read ([Note.reads]), which its printed
  /// footprint leaves out: the code's alone. The definitions they call by
  /// name are their owners' to resolve.
  Map<ActivationStep, Reads> get noteReads {
    final out = <ActivationStep, Reads>{};
    for (final (:step, place: _) in steps) {
      for (final arm in step.allArms) {
        for (final e in arm.then) {
          if (e case Note(:final reads)) {
            out[step.name] = (out[step.name] ?? Reads.none) + reads;
          }
        }
      }
    }
    return out;
  }

  /// What each step's action reads and writes of the shared state, from
  /// the declarations it prints from: its guards, picks, effects, call and
  /// the reads recorded on entering the place it goes to ([entered], as
  /// [tla] takes it), and what each arm does to the flow's own row. The
  /// definitions it calls by name are its owners' to resolve.
  /// [starts] is every table's inputs by name, for the steps that spawn one
  /// ([Spawn]).
  List<Footprint> footprints({
    Map<String, List<Assign<Object?>>>? entered,
    Map<ActivationStep, Step<Object?, Enum>> starts = const {},
  }) => [
    for (final (:place, :step) in steps)
      if (!step.spawned)
      _footprint(
        step,
        place: place,
        places: places,
        ending: ending,
        entered: entered ?? readsByPlace,
        starts: starts,
      ),
  ];

  /// The places whose step may start another table's input in its own
  /// turn ([Spawn]).
  List<P> get spawningPlaces => [
    for (final (:place, :step) in steps)
      if (step.allArms.any((a) => a.then.any((e) => e is Spawn<W>))) place,
  ];

  static Footprint _footprint<W, P extends Enum>(
    Step<W, P> s, {
    required P place,
    required Iterable<P> places,
    required Set<P> ending,
    required Map<String, List<Assign<Object?>>> entered,
    required Map<ActivationStep, Step<Object?, Enum>> starts,
  }) {
    final call = s.call;
    final arms = s.allArms;
    List<Assign<Object?>> entering(Arm<Object?, Enum> arm) => [
      for (final MapEntry(key: p, value: rs) in entered.entries)
        if (arm.next.tla == '"$p"') ...rs,
    ];
    Iterable<Arm<Object?, Enum>> started(Arm<W, P> arm) => [
      for (final e in arm.then)
        if (e is Spawn<W>) _spawned(e, starts: starts).otherwise,
    ];
    Reads readsOf(Effect<Object?> e) => switch (e) {
      Act(:final reads) => reads,
      Assign(:final reads) => reads,
      Note() => Reads.none,
      Spawn(when: final holds, :final site) =>
        const Reads(vars: {ModelVar.inputs}) + holds.reads + site.reads,
    };
    final reads = Reads.of([
      if (s.input) const Reads(vars: {ModelVar.inputs}, base: {BaseOp.input}),
      if (s.granted) const Reads(base: {BaseOp.granted}),
      ?s.enabled?.reads,
      ?s.pick?.from.reads,
      ?s.site?.reads,
      ?s.tab?.reads,
      for (final b in s.branches) b.when.reads,
      ?s.refused?.when.reads,
      if (call != null) ...[
        for (final w in call.writes) w.reads,
        ?call.keeps?.reads,
      ],
      for (final arm in arms) ...[
        ?arm.pick?.from.reads,
        ?arm.site?.reads,
        ?arm.tab?.reads,
        arm.next.reads,
        for (final e in arm.then) readsOf(e),
        for (final r in entering(arm)) r.reads,
        for (final i in started(arm)) ...[
          i.next.reads,
          for (final e in i.then) readsOf(e),
          for (final r in entering(i)) r.reads,
        ],
      ],
    ]);
    final writes = {
      ModelVar.fl,
      ModelVar.last,
      if (s.input) ModelVar.inputs,
      for (final w in call?.writes ?? <Write<W>>[]) w.variable,
      for (final arm in arms)
        for (final e in [...arm.then, for (final i in started(arm)) ...i.then])
          if (e case Act(:final writes))
            ...writes
          else if (e is Spawn<W>)
            ModelVar.inputs,
    };
    // An arm is taken only once the branches before it did not hold: it
    // needs what each needs not to hold, and a branch on the flow's kind
    // leaves it the other kinds.
    Set<Need> passed(int i) => {
      for (final b in s.branches.take(i)) ...b.when.unless,
    };
    ArmRow row(Arm<W, P> arm, {required int at}) {
      // Each place the arm may go to, with what going there needs.
      final next = <String, Set<Need>>{};
      for (final (:needs, :tla) in arm.next.cases) {
        for (final p in places) {
          if (!tla.contains('"${p.name}"')) continue;
          next[p.name] = switch (next[p.name]) {
            null => needs,
            final was => was.intersection(needs),
          };
        }
      }
      assert(next.isNotEmpty, '${s.name} goes to no place: ${arm.next.tla}');
      final kinds = _kindsSet(arm, by: s.name);
      final ends = ending.any((p) => arm.next.tla == '"${p.name}"');
      return (
        next: next,
        kind: kinds.firstOrNull,
        ends: ends,
        needs: {
          if (arm case Refused(when: final w)) ...w.needs else ...passed(at),
          if (arm case Branch(when: final w)) ...w.needs,
          ...?arm.pick?.from.needs,
        },
        only: _only(s, at: at),
        fields: ends
            ? FlowField.values.toSet()
            : {
                FlowField.pc,
                if (arm is! Refused) ?call?.keeps?.field,
                for (final e in arm.then)
                  if (e case Assign(:final field)) field,
                for (final r in entering(arm)) r.field,
              },
        spawns: [
          for (final e in arm.then)
            if (e is Spawn<W>)
              if (_spawned(e, starts: starts).otherwise case final i)
                (
                  kind: _kindsSet(i, by: e.input).single,
                  next: {
                    for (final (:needs, :tla) in i.next.cases)
                      _placeNamed(tla, by: e.input): needs,
                  },
                  fields: {
                    FlowField.pc,
                    for (final e in i.then)
                      if (e case Assign(:final field)) field,
                    for (final r in entering(i)) r.field,
                  },
                  needs: e.when.needs,
                ),
        ],
      );
    }

    return (
      step: s.name,
      place: place.name,
      input: s.input,
      reads: reads,
      writes: writes,
      needs: {...?s.enabled?.needs, ...?s.pick?.from.needs},
      guard: {...?s.enabled?.reads.vars},
      arms: [for (final (i, arm) in arms.indexed) row(arm, at: i)],
    );
  }

  /// The table's steps as TLA+ actions over [variables], each branch
  /// setting what it writes and holding the rest; [entered] is every
  /// table's [readsByPlace] when a flow crosses tables, else this one's.
  String tla({
    required List<ModelVar> variables,
    Map<String, List<Assign<Object?>>>? entered,
    Map<ActivationStep, Step<Object?, Enum>> starts = const {},
    TlaGuardOrder guardOrder = TlaGuardOrder.preferred,
  }) => [
    for (final (:place, :step) in steps)
      if (!step.spawned)
      _action<W, P>(
        step,
        place: place,
        context: (
          variables: variables,
          ending: ending,
          awaited: awaited.contains(place),
          entered: entered ?? readsByPlace,
          starts: starts,
          guardOrder: guardOrder,
        ),
      ).text,
  ].join('\n');

  /// Each step's action as the alternatives it takes, one per arm (and per
  /// side of an arm's spawn), each the step's guard and the conditions that
  /// lead to the arm beside it: their disjunction is the action, so a proof
  /// can take one arm at a time.
  Map<ActivationStep, List<StepAlternative>> alternatives({
    required List<ModelVar> variables,
    Map<String, List<Assign<Object?>>>? entered,
    Map<ActivationStep, Step<Object?, Enum>> starts = const {},
    TlaGuardOrder guardOrder = TlaGuardOrder.preferred,
  }) => {
    for (final (:place, :step) in steps)
      if (!step.spawned)
        step.name: _action<W, P>(
          step,
          place: place,
          context: (
            variables: variables,
            ending: ending,
            awaited: awaited.contains(place),
            entered: entered ?? readsByPlace,
            starts: starts,
            guardOrder: guardOrder,
          ),
        ).alternatives,
  };

  static ({String text, List<StepAlternative> alternatives})
  _action<W, P extends Enum>(
    Step<W, P> s, {
    required P place,
    required _ActionContext<P> context,
  }) {
    final (:variables, :ending, :awaited, :entered, :starts, :guardOrder) = context;
    final guard = guardOrder.arrange([
      if (s.input) ...[
        'Input',
        'f = inputs + 1',
      ] else ...[
        if ((!s.internal || awaited) && !s.granted) 'Calm',
        'fl[f].pc = "${place.name}"',
        if (s.granted) 'Granted(f)',
      ],
    ]);
    // The reply lands before the arms run, so within the step a read of
    // the field that keeps it is the reply; outside, the field. A refused
    // reply lands nothing: its arm writes none of the call's variables and
    // reads the field as it was.
    final replied = _replied(s);
    ({String text, List<StepAlternative> sides}) branch(Arm<W, P> arm) {
      final (:got, :callWrites, :ends, :acts, :written, :assigns) = _parts(
        s,
        arm: arm,
        replied: replied,
        ending: ending,
        entered: entered,
      );
      // A spawned input reads the state the arm leaves, as primed names,
      // so its row and its writes follow the arm's writes.
      String body({_Started? started}) {
        final all = {...written, ...?started?.written};
        final held = [
          for (final v in variables)
            if (!all.contains(v)) v.name,
        ];
        final row =
            "fl' = [fl EXCEPT ${[if (ends) '![f] = NoFlow' else ...assigns, ...?started?.assigns].join(', ')}]";
        return [
          if (started != null) 'Starts',
          for (final w in callWrites) w.tla,
          if (started == null) row,
          for (final a in acts) got(a.tla),
          if (started != null) ...[for (final a in started.acts) a.tla, row],
          'Did("${s.action}", f, "${arm.outcome.tla}", ${got((arm.tab ?? s.tab ?? arm.site ?? s.site)?.tla ?? '0')})',
          if (held.isNotEmpty) 'UNCHANGED << ${held.join(', ')} >>',
        ].map((c) => '($c)').join(' /\\ ');
      }

      final spawns = [
        for (final e in arm.then)
          if (e is Spawn<W>) e,
      ];
      assert(spawns.length < 2, '${s.name} spawns twice in one arm');
      final plain = body();
      var text = plain;
      var sides = [(tla: plain, spawns: false)];
      if (spawns.firstOrNull case final spawn?) {
        final started = _start(
          spawn,
          starts: starts,
          entered: entered,
          after: written,
          bound: {s.pick?.name, arm.pick?.name},
        );
        final when = got(spawn.when.tla);
        final spawning =
            '(LET ${started.pick} == ${got(spawn.site.tla)} IN ${body(started: started)})';
        text = 'IF $when\n         THEN $spawning\n         ELSE ($plain)';
        sides = [
          (tla: '($when) /\\ $spawning', spawns: true),
          (tla: '~($when) /\\ ($plain)', spawns: false),
        ];
      }
      if (arm.pick case final p?) {
        // The spawn's condition may read the pick, so the arm stays whole.
        // Its conditional spawn is not exposed as an unconditional one.
        final picked = '\\E ${p.name} \\in ${got(p.from.tla)} : ($text)';
        return (
          text: picked,
          sides: [(tla: picked, spawns: false)],
        );
      }
      return (text: text, sides: sides);
    }

    final arms = [for (final b in s.branches) branch(b)];
    final otherwise = branch(s.otherwise);
    var choice = '(${otherwise.text})';
    for (final (i, b) in s.branches.indexed.toList().reversed) {
      choice =
          'IF ${replied(b.when.tla)}\n         THEN (${arms[i].text})\n         ELSE $choice';
    }
    // Branch i is taken when the ones before it do not hold and it does.
    final whens = [for (final b in s.branches) '(${replied(b.when.tla)})'];
    var alternatives = [
      for (final (i, arm) in [...arms, otherwise].indexed)
        for (final side in arm.sides)
          (
            tla: [
              for (final w in whens.take(i)) '~$w',
              if (i < whens.length) whens[i],
              '(${side.tla})',
            ].join(' /\\ '),
            spawns: side.spawns,
          ),
    ];
    if (s.refused case final r?) {
      final refused = '(${r.when.tla}) /\\ (${branch(r).text})';
      choice = '($choice)\n         \\/ ($refused)';
      alternatives = [
        ...alternatives,
        (tla: refused, spawns: false),
      ];
    }
    final guarded = switch (s.enabled) {
      null => choice,
      final e => '(${e.tla})\n         /\\ ($choice)',
    };
    final body = switch (s.pick) {
      null => guarded,
      final p => '\\E ${p.name} \\in ${p.from.tla} :\n         $guarded',
    };
    return (
      text: [
        '${s.action}(f) ==',
        for (final g in guard) '    /\\ $g',
        '    /\\ $body',
        '',
      ].join('\n'),
      alternatives: [
        for (final a in alternatives)
          (
            tla: [
              for (final g in guard) '($g)',
              switch ((s.enabled, s.pick)) {
                (null, null) => '(${a.tla})',
                (final e?, null) => '(${e.tla}) /\\ (${a.tla})',
                (null, final p?) =>
                  '(\\E ${p.name} \\in ${p.from.tla} : (${a.tla}))',
                (final e?, final p?) =>
                  '(\\E ${p.name} \\in ${p.from.tla} : ((${e.tla}) /\\ (${a.tla})))',
              },
            ].join(' /\\ ').replaceAll(RegExp(r'\n\s*'), ' '),
            spawns: a.spawns,
          ),
      ],
    );
  }

  /// The branches before arm [at] of [s], which it is taken only once they
  /// did not hold. A refused reply takes its arm whatever the branches say.
  static List<Branch<W, P>> _passed<W, P extends Enum>(Step<W, P> s, {required int at}) =>
      s.allArms[at] is Refused ? const [] : s.branches.take(at).toList();

  /// The kinds of flow [arm]'s own branch holds for, null when it does not
  /// test the kind.
  static Set<FlowKind>? _tested<W, P extends Enum>(Arm<W, P> arm) => switch (arm) {
    Branch(when: final w) => w.kinds,
    Otherwise() || Refused() => null,
  };

  /// The kinds of flow arm [at] of [s] is taken for, null for any: those
  /// its branch holds for, less those the branches before it took.
  static Set<FlowKind>? _only<W, P extends Enum>(Step<W, P> s, {required int at}) {
    var left = _tested(s.allArms[at]);
    for (final b in _passed(s, at: at)) {
      if (!b.when.exactKinds) continue;
      left = (left ?? FlowKind.values.toSet()).difference(b.when.kinds!);
    }
    return left;
  }

  /// The step's reads of the field its call keeps, as the reply: the reply
  /// lands before the arms run.
  static String Function(String) _replied<W, P extends Enum>(Step<W, P> s) =>
      switch (s.call?.keeps) {
        null => (String tla) => tla,
        (:final field, :final reply, reads: _) => (String tla) => tla.replaceAll(
          RegExp('fl\\[f\\]\\.${field.name}\\b'),
          '($reply)',
        ),
      };

  /// Each step's writes of `fl` as its action prints them, for the proof
  /// that every step keeps the flows' rows typed: per arm, the picks it
  /// binds, the guards it is taken under and the clauses of its row, and for
  /// an arm that starts a flow, a second row with the started flow's clauses
  /// beside its own.
  List<FlStep> flSteps({
    Map<String, List<Assign<Object?>>>? entered,
    Map<ActivationStep, Step<Object?, Enum>> starts = const {},
  }) => [
    for (final (:place, :step) in steps)
      if (!step.spawned)
        _flStep(
          step,
          place: place.name,
          ending: ending,
          entered: entered ?? readsByPlace,
          starts: starts,
        ),
  ];

  static FlStep _flStep<W, P extends Enum>(
    Step<W, P> s, {
    required String place,
    required Set<P> ending,
    required Map<String, List<Assign<Object?>>> entered,
    required Map<ActivationStep, Step<Object?, Enum>> starts,
  }) {
    final replied = _replied(s);
    return (
      action: s.action,
      input: s.input,
      place: place,
      rows: [
        for (final (at, arm) in s.allArms.indexed) ...() {
          final (:got, :ends, :assigns, :written, :callWrites, :acts) =
              _parts(s, arm: arm, replied: replied, ending: ending, entered: entered);
          final writes = [
            for (final w in callWrites) (vars: {w.variable}, tla: w.tla),
            for (final a in acts) (vars: a.writes, tla: got(a.tla)),
          ];
          final own = ends ? ['![f] = NoFlow'] : assigns;
          final picks = [
            if (s.pick case final p?) (name: p.name, from: p.from.tla),
            if (arm.pick case final p?) (name: p.name, from: got(p.from.tla)),
          ];
          final given = [
            ?s.enabled?.tla,
            ...switch (arm) {
              Branch(when: final b) => [replied(b.tla)],
              Refused(when: final r) => [r.tla],
              Otherwise() => const <String>[],
            },
          ];
          final spawn = arm.then.whereType<Spawn<W>>().firstOrNull;
          final tested = _tested(arm);
          final passed = [
            for (final b in _passed(s, at: at))
              (
                tla: '~(${replied(b.when.tla)})',
                kinds: b.when.exactKinds ? b.when.kinds! : const <FlowKind>{},
              ),
          ];
          return [
            (
              picks: picks,
              lets: const <({String name, String to})>[],
              given: given,
              clauses: own,
              tested: tested,
              passed: passed,
              writes: writes,
            ),
            if (spawn != null)
              () {
                final started = _start(
                  spawn,
                  starts: starts,
                  entered: entered,
                  after: written,
                  bound: {s.pick?.name, arm.pick?.name},
                );
                return (
                  picks: picks,
                  lets: [(name: started.pick, to: got(spawn.site.tla))],
                  given: [...given, got(spawn.when.tla)],
                  clauses: [...own, ...started.assigns],
                  tested: tested,
                  passed: passed,
                  writes: [...writes, ...started.acts],
                );
              }(),
          ];
        }(),
      ],
    );
  }

  /// What [arm] of [s] writes as its action prints it: the call's and the
  /// acts' writes, and the clauses of its own row of `fl` (the place it goes
  /// to and the fields it sets), read through [replied] unless the platform
  /// refused the call; [ends] when the arm ends the flow, its row `NoFlow`.
  static ({
    String Function(String) got,
    List<Write<W>> callWrites,
    bool ends,
    List<Act<W>> acts,
    Set<ModelVar> written,
    List<String> assigns,
  })
  _parts<W, P extends Enum>(
    Step<W, P> s, {
    required Arm<W, P> arm,
    required String Function(String) replied,
    required Set<P> ending,
    required Map<String, List<Assign<Object?>>> entered,
  }) {
    final refused = arm is Refused;
    final got = refused ? (String tla) => tla : replied;
    final callWrites = refused ? <Write<W>>[] : s.call?.writes ?? <Write<W>>[];
    final ends = ending.any((p) => arm.next.tla == '"${p.name}"');
    final own = [
      if (s.call?.keeps case final k? when !refused)
        (field: k.field.name, to: k.reply),
      for (final e in arm.then)
        if (e case Assign(:final field, :final to))
          (field: field.name, to: got(to)),
    ];
    final acts = [
      for (final e in arm.then)
        if (e is Act<W>) e,
    ];
    final written = {
      for (final w in callWrites) w.variable,
      for (final a in acts) ...a.writes,
      ModelVar.fl,
      ModelVar.last,
      if (s.input) ModelVar.inputs,
    };
    // The next place's call starts once the arm is done, so what it reads
    // is the arm's own state: a field the arm sets reads as set (its value
    // is the arm's, over the state the arm found), and a variable the arm
    // writes it may not read, since the model would read the old value
    // (an assert); the place is entered by name, since the reads are its
    // arm's.
    final next = got(arm.next.tla);
    final entering = [
      for (final MapEntry(key: p, value: rs) in entered.entries)
        if (next == '"$p"') ...rs,
    ];
    assert(
      entered.keys.every((p) => next == '"$p"' || !next.contains('"$p"')),
      '${s.name} enters $next, a place whose call reads, not by name',
    );
    assert(
      entering.every(
        (r) => written
            .difference({ModelVar.fl, ModelVar.last, ModelVar.inputs})
            .every((v) => !RegExp('\\b${v.name}\\b').hasMatch(r.to)),
      ),
      '${s.name} writes what the next call reads at its start',
    );
    final reads = [
      for (final r in entering) (field: r.field.name, to: _after(r.to, own: own)),
    ];
    final assigns = [
      '![f].pc = $next',
      for (final (:field, :to) in [...own, ...reads]) '![f].$field = $to',
    ];
    assert(
      acts.every(
        (a) => a.writes.every(
          (w) => !callWrites.any((cw) => cw.variable == w),
        ),
      ),
      '${s.name} writes a variable its call writes',
    );
    return (
      got: got,
      callWrites: callWrites,
      ends: ends,
      acts: acts,
      written: written,
      assigns: assigns,
    );
  }

  /// What [spawn]'s input prints in the action of the step that starts it:
  /// its row's fields on the flow numbered next and its writes, over the
  /// state the arm leaves (each variable the arm writes, in [after], primed),
  /// its pick bound to the spawn's site. The spawn's condition and site are
  /// read before the arm's writes, so they read none of them.
  static _Started _start<W>(
    Spawn<W> spawn, {
    required Map<ActivationStep, Step<Object?, Enum>> starts,
    required Map<String, List<Assign<Object?>>> entered,
    required Set<ModelVar> after,
    required Set<String?> bound,
  }) {
    final input = _spawned(spawn, starts: starts);
    final arm = input.otherwise;
    final primed = after.difference({ModelVar.fl, ModelVar.last});
    assert(
      [
        spawn.when,
        spawn.site,
      ].every((e) => e.reads.vars.intersection(primed).isEmpty),
      'the spawn of ${spawn.input} reads what its arm writes',
    );
    assert(
      !bound.contains(input.pick!.name),
      'the spawn of ${spawn.input} binds ${input.pick!.name}, which its step '
      'binds too',
    );
    String fresh(String tla) {
      var t = tla;
      for (final v in primed) {
        t = t.replaceAll(RegExp("\\b${v.name}\\b(?!')"), "${v.name}'");
      }
      return t.replaceAll(RegExp(r'\bf\b'), '(inputs + 1)');
    }

    final own = [
      for (final e in arm.then)
        if (e case Assign(:final field, :final to)) (field: field.name, to: to),
    ];
    final next = arm.next.tla;
    final acts = [
      for (final e in arm.then)
        if (e case final Act<Object?> a) a,
    ];
    final written = {for (final a in acts) ...a.writes, ModelVar.inputs};
    assert(
      written.intersection(after).isEmpty,
      'the spawn of ${spawn.input} writes what its arm writes',
    );
    return (
      pick: input.pick!.name,
      assigns: [
        '![inputs + 1].pc = ${fresh(next)}',
        for (final (:field, :to) in [
          ...own,
          for (final MapEntry(key: p, value: rs) in entered.entries)
            if (next == '"$p"')
              for (final r in rs)
                (field: r.field.name, to: _after(r.to, own: own)),
        ])
          '![inputs + 1].$field = ${fresh(to)}',
      ],
      acts: [for (final a in acts) (vars: a.writes, tla: fresh(a.tla))],
      written: written,
    );
  }

  /// [to] over the state after an arm's [own] field assigns.
  static String _after(
    String to, {
    required List<({String field, String to})> own,
  }) {
    var text = to;
    for (final (:field, to: value) in own) {
      text = text.replaceAll(RegExp('fl\\[f\\]\\.$field\\b'), '($value)');
    }
    return text;
  }
}

/// A row of `fl` an arm writes, as its action prints it: the picks bound
/// around it, the names a started flow's pick is bound to, the guards it
/// is taken under, the clauses of `[fl EXCEPT ...]`, the kinds of flow its
/// own branch holds for (null when it does not test the kind), and the
/// branches before it, which did not hold, each with the kinds it holds
/// for exactly (none when it is not a test of the kind alone), and its
/// writes of the other variables, each with those it writes.
typedef FlRow = ({
  List<({String name, String from})> picks,
  List<({String name, String to})> lets,
  List<String> given,
  List<String> clauses,
  Set<FlowKind>? tested,
  List<({String tla, Set<FlowKind> kinds})> passed,
  List<({Set<ModelVar> vars, String tla})> writes,
});

/// A step's action, whether it is an input, the place it runs from, and the
/// rows of `fl` its arms write.
typedef FlStep = ({String action, bool input, String place, List<FlRow> rows});

/// What a spawned input prints in the action that starts it: the name its
/// pick binds, its row's fields, its writes and the variables they write.
typedef _Started = ({
  String pick,
  List<String> assigns,
  List<({Set<ModelVar> vars, String tla})> acts,
  Set<ModelVar> written,
});

/// The input [spawn] starts, among [starts]: an input's own step with one
/// arm, no guard, and a pick its spawn binds to its site.
Step<Object?, Enum> _spawned(
  Spawn<Object?> spawn, {
  required Map<ActivationStep, Step<Object?, Enum>> starts,
}) {
  final input = starts[spawn.input];
  assert(
    input != null && input.input,
    '${spawn.input} is no input of the tables printed with its spawn',
  );
  assert(
    input!.branches.isEmpty &&
        input.enabled == null &&
        input.pick != null &&
        input.otherwise.pick == null &&
        !input.otherwise.then.any((e) => e is Spawn),
    'a spawned input has one arm, no guard and a pick its spawn binds',
  );
  return input!;
}

/// The kinds [arm] gives its flow: none, or the one its `kind` takes.
List<FlowKind> _kindsSet(Arm<Object?, Enum> arm, {required ActivationStep by}) {
  final kinds = [
    for (final e in arm.then)
      if (e case Assign(field: FlowField.kind, :final to))
        FlowKind.values.singleWhere(
          (k) => to == '"${k.name}"',
          orElse: () => throw StateError(
            '$by gives its flow a kind no FlowKind names: $to',
          ),
        ),
  ];
  assert(kinds.length < 2, '$by sets its kind twice in one arm');
  return kinds;
}

/// The place [tla] names, `"<name>"`: one a spawned input goes to.
String _placeNamed(String tla, {required ActivationStep by}) =>
    RegExp(r'^"(\w+)"$').firstMatch(tla)?[1] ??
    (throw StateError('$by goes to $tla, which names no one place'));
