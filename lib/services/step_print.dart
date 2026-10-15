import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';

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
        for (final e in [
          ...arm.then,
          for (final i in started(arm)) ...i.then,
        ])
          if (e case Act(:final writes)) ...writes
          else if (e is Spawn<W>) ModelVar.inputs,
    };
    // An arm is taken only once the branches before it did not hold: it
    // needs what each needs not to hold, and a branch on the flow's kind
    // leaves it the other kinds.
    Set<Need> passed(int i) => {
      for (final b in s.branches.take(i)) ...b.when.unless,
    };
    // A refused reply takes its arm whatever the branches say.
    Set<FlowKind>? only(int i) {
      Set<FlowKind>? left = switch (arms[i]) {
        Branch(when: final w) => w.kinds,
        Otherwise() || Refused() => null,
      };
      if (arms[i] is Refused) return left;
      for (final b in s.branches.take(i)) {
        if (!b.when.exactKinds) continue;
        left = (left ?? FlowKind.values.toSet()).difference(b.when.kinds!);
      }
      return left;
    }
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
        only: only(at),
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
  }) => [
    for (final (:place, :step) in steps)
      if (!step.spawned)
      _action(
        step,
        place: place,
        variables: variables,
        ending: ending,
        awaited: awaited.contains(place),
        entered: entered ?? readsByPlace,
        starts: starts,
      ),
  ].join('\n');

  static String _action<W, P extends Enum>(
    Step<W, P> s, {
    required P place,
    required List<ModelVar> variables,
    required Set<P> ending,
    required bool awaited,
    required Map<String, List<Assign<Object?>>> entered,
    required Map<ActivationStep, Step<Object?, Enum>> starts,
  }) {
    final guard = [
      if (s.input) ...[
        'Input',
        'f = inputs + 1',
      ] else ...[
        if ((!s.internal || awaited) && !s.granted) 'Calm',
        'fl[f].pc = "${place.name}"',
        if (s.granted) 'Granted(f)',
      ],
    ];
    // The reply lands before the arms run, so within the step a read of
    // the field that keeps it is the reply; outside, the field. A refused
    // reply lands nothing: its arm writes none of the call's variables and
    // reads the field as it was.
    final replied = switch (s.call?.keeps) {
      null => (String tla) => tla,
      (:final field, :final reply, reads: _) => (String tla) => tla.replaceAll(
        RegExp('fl\\[f\\]\\.${field.name}\\b'),
        '($reply)',
      ),
    };
    String branch(Arm<W, P> arm) {
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
          if (started != null) ...[...started.acts, row],
          'Did("${s.action}", f, "${arm.outcome.tla}", ${got((arm.tab ?? s.tab ?? arm.site ?? s.site)?.tla ?? '0')})',
          if (held.isNotEmpty) 'UNCHANGED << ${held.join(', ')} >>',
        ].map((c) => '($c)').join(' /\\ ');
      }

      final spawns = [
        for (final e in arm.then)
          if (e is Spawn<W>) e,
      ];
      assert(spawns.length < 2, '${s.name} spawns twice in one arm');
      var text = body();
      if (spawns.firstOrNull case final spawn?) {
        final started = _start(
          spawn,
          starts: starts,
          entered: entered,
          after: written,
          bound: {s.pick?.name, arm.pick?.name},
        );
        text =
            'IF ${got(spawn.when.tla)}\n         THEN (LET ${started.pick} == '
            '${got(spawn.site.tla)} IN ${body(started: started)})\n'
            '         ELSE ($text)';
      }
      return switch (arm.pick) {
        null => text,
        final p => '\\E ${p.name} \\in ${got(p.from.tla)} : ($text)',
      };
    }

    var choice = '(${branch(s.otherwise)})';
    for (final b in s.branches.reversed) {
      choice =
          'IF ${replied(b.when.tla)}\n         THEN (${branch(b)})\n         ELSE $choice';
    }
    if (s.refused case final r?) {
      choice = '($choice)\n         \\/ ((${r.when.tla}) /\\ (${branch(r)}))';
    }
    final guarded = switch (s.enabled) {
      null => choice,
      final e => '(${e.tla})\n         /\\ ($choice)',
    };
    final body = switch (s.pick) {
      null => guarded,
      final p => '\\E ${p.name} \\in ${p.from.tla} :\n         $guarded',
    };
    return [
      '${s.action}(f) ==',
      for (final g in guard) '    /\\ $g',
      '    /\\ $body',
      '',
    ].join('\n');
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
      [spawn.when, spawn.site].every(
        (e) => e.reads.vars.intersection(primed).isEmpty,
      ),
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
      acts: [for (final a in acts) fresh(a.tla)],
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

/// What a spawned input prints in the action that starts it: the name its
/// pick binds, its row's fields, its writes and the variables they write.
typedef _Started = ({
  String pick,
  List<String> assigns,
  List<String> acts,
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
