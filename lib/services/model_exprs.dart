part of 'step_table.dart';

/// The model's operators over values as [Expr]s: each runs on the code's
/// value and prints as the model's text, grouped as the tree that runs.

/// [tla] as an operand: in parentheses when an operator sits at its top
/// level (a space outside every bracket), so the printed text groups as
/// the tree that runs does; a name, a call or an indexing stands alone.
String tlaOperand(String tla) {
  var depth = 0;
  for (final r in tla.runes) {
    switch (String.fromCharCode(r)) {
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}':
        depth--;
      case ' ' when depth == 0:
        return '($tla)';
    }
  }
  return tla;
}

/// `{e}`.
extension SingletonExpr<E, W> on Expr<E, W> {
  Expr<List<E>, W> get asSet =>
      Expr._(run: (c) => [run(c)], tla: '{$tla}', reads: reads);
}

/// A value the model writes 0 for when there is none, as a set: empty, or
/// the value alone.
extension OptionalExpr<E extends Object, W> on Expr<E?, W> {
  Expr<List<E>, W> get orNone => Expr._(
    run: (c) => [?run(c)],
    tla: 'IF ${tlaOperand(tla)} = 0 THEN {} ELSE {$tla}',
    reads: reads,
  );
}

/// `r.name`: one field of a record the model keeps as one variable.
extension RecordExpr<R, W> on Expr<R, W> {
  Expr<V, W> part<V>(String name, {required V Function(R record) get}) =>
      Expr._(run: (c) => get(run(c)), tla: '${tlaOperand(tla)}.$name', reads: reads);
}

/// A function of the model held whole (`file`, the platform's), indexed
/// and updated an entry at a time.
extension FunctionExpr<K, V, W> on Expr<Map<K, V>, W> {
  /// `F[k]`.
  Expr<V, W> at(Expr<K, W> k) => Expr._(
    run: (c) => run(c)[k.run(c)] as V,
    tla: '${tlaOperand(tla)}[${k.tla}]',
    reads: reads + k.reads,
  );

  /// `[F EXCEPT ![k] = v]`.
  Expr<Map<K, V>, W> except(Expr<K, W> k, {required Expr<V, W> to}) => Expr._(
    run: (c) => {...run(c), k.run(c): to.run(c)},
    tla: '[${tlaOperand(tla)} EXCEPT ![${k.tla}] = ${to.tla}]',
    reads: reads + k.reads + to.reads,
  );

  /// `[k \in DOMAIN F |-> IF k \in ks THEN v ELSE F[k]]`: every key of
  /// [ks] to one value.
  Expr<Map<K, V>, W> exceptAll(
    Expr<Iterable<K>, W> ks, {
    required Expr<V, W> to,
  }) => Expr._(
    run: (c) {
      final keys = ks.run(c).toSet();
      final v = to.run(c);
      return {
        for (final MapEntry(:key, :value) in run(c).entries)
          key: keys.contains(key) ? v : value,
      };
    },
    tla:
        '[k \\in DOMAIN ${tlaOperand(tla)} |-> IF k \\in ${tlaOperand(ks.tla)} '
        'THEN ${to.tla} ELSE ${tlaOperand(tla)}[k]]',
    reads: reads + ks.reads + to.reads,
  );
}

/// A function of functions, `F[k][j]`, updated one inner entry at a time.
extension Function2Expr<K, J, V, W> on Expr<Map<K, Map<J, V>>, W> {
  /// `[F EXCEPT ![k][j] = v]`.
  Expr<Map<K, Map<J, V>>, W> exceptAt(
    Expr<K, W> k, {
    required Expr<J, W> at,
    required Expr<V, W> to,
  }) => Expr._(
    run: (c) {
      final f = run(c);
      final key = k.run(c);
      return {
        ...f,
        key: {...f[key]!, at.run(c): to.run(c)},
      };
    },
    tla: '[${tlaOperand(tla)} EXCEPT ![${k.tla}][${at.tla}] = ${to.tla}]',
    reads: reads + k.reads + at.reads + to.reads,
  );
}

extension IntExpr<W> on Expr<int, W> {
  Expr<int, W> plus(int n) =>
      Expr._(run: (c) => run(c) + n, tla: '${tlaOperand(tla)} + $n', reads: reads);

  /// `a <= b`.
  Expr<bool, W> isAtMost(Expr<int, W> other) => Expr._(
    run: (c) => run(c) <= other.run(c),
    tla: '${tlaOperand(tla)} <= ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
  );

  /// `a > b`.
  Expr<bool, W> exceeds(Expr<int, W> other) => Expr._(
    run: (c) => run(c) > other.run(c),
    tla: '${tlaOperand(tla)} > ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
  );

  /// The lesser of this and [other].
  Expr<int, W> atMost(Expr<int, W> other) => Expr._(
    run: (c) {
      final a = run(c), b = other.run(c);
      return a < b ? a : b;
    },
    tla: 'IF ${tlaOperand(tla)} > ${tlaOperand(other.tla)} THEN ${tlaOperand(other.tla)} ELSE ${tlaOperand(tla)}',
    reads: reads + other.reads,
  );

  /// How far this exceeds [cap], `0` when it does not.
  Expr<int, W> over(Expr<int, W> cap) => Expr._(
    run: (c) {
      final excess = run(c) - cap.run(c);
      return excess > 0 ? excess : 0;
    },
    tla:
        'IF ${tlaOperand(tla)} > ${tlaOperand(cap.tla)} '
        'THEN ${tlaOperand(tla)} - ${tlaOperand(cap.tla)} ELSE 0',
    reads: reads + cap.reads,
  );
}

/// A record of the model, `[t |-> s, v |-> version + 1]`, built in the code
/// by [run] from the same [fields].
Expr<V, W> record<V, W>(
  Map<String, Expr<Object?, W>> fields, {
  required V Function(StepView<W> c) run,
}) => Expr._(
  run: run,
  tla:
      '[${[for (final MapEntry(key: k, value: e) in fields.entries) '$k |-> ${e.tla}'].join(', ')}]',
  reads: Reads.of([for (final e in fields.values) e.reads]),
);

extension BoolExpr<W> on Expr<bool, W> {
  Expr<bool, W> operator &(Expr<bool, W> other) => Expr._(
    run: (c) => run(c) && other.run(c),
    tla: '${tlaOperand(tla)} /\\ ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
    needs: {...needs, ...other.needs},
    unless: unless.intersection(other.unless),
    kinds: switch ((kinds, other.kinds)) {
      (null, final k) || (final k, null) => k,
      (final a?, final b?) => a.intersection(b),
    },
    exactKinds: exactKinds && other.exactKinds,
  );

  Expr<bool, W> operator |(Expr<bool, W> other) => Expr._(
    run: (c) => run(c) || other.run(c),
    tla: '${tlaOperand(tla)} \\/ ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
    needs: needs.intersection(other.needs),
    unless: {...unless, ...other.unless},
    kinds: switch ((kinds, other.kinds)) {
      (final a?, final b?) => a.union(b),
      _ => null,
    },
    exactKinds: exactKinds && other.exactKinds,
  );

  /// Holds where this does not: what it needs is what this needs not to
  /// hold, and a test of the flow's kind holds for the other kinds.
  Expr<bool, W> operator ~() => Expr._(
    run: (c) => !run(c),
    tla: '~($tla)',
    reads: reads,
    needs: unless,
    unless: needs,
    kinds: exactKinds ? FlowKind.values.toSet().difference(kinds!) : null,
    exactKinds: exactKinds,
  );
}

extension KindField<W> on Field<FlowKind, W> {
  /// `fl[f].kind = "<kind>"`: holds for a row of [kind] and no other.
  Expr<bool, W> isKind(FlowKind kind) => Expr._(
    run: (c) => of(c) == kind,
    tla: 'fl[f].$tla = "${kind.name}"',
    reads: Reads.none,
    kinds: {kind},
    exactKinds: true,
  );
}

/// A list or set of the code's as the model's set: its order and repeats
/// are the code's alone.
extension SetExpr<E, W> on Expr<Iterable<E>, W> {
  Expr<bool, W> get isEmpty => Expr._(
    run: (c) => run(c).isEmpty,
    tla: '${tlaOperand(tla)} = {}',
    reads: reads,
    unless: needs,
  );

  /// `S # {}`: needs what S needs to have members.
  Expr<bool, W> get isNotEmpty => Expr._(
    run: (c) => run(c).isNotEmpty,
    tla: '${tlaOperand(tla)} # {}',
    reads: reads,
    needs: needs,
  );

  /// `e \in S`; [e] may be of a wider type (`0` for no site), then it is
  /// not in.
  Expr<bool, W> has(Expr<Object?, W> e) => Expr._(
    run: (c) => run(c).contains(e.run(c)),
    tla: '${tlaOperand(e.tla)} \\in ${tlaOperand(tla)}',
    reads: reads + e.reads,
    needs: needs,
  );

  /// `S = {e}`.
  Expr<bool, W> isOnly(Expr<E, W> e) => Expr._(
    run: (c) {
      final x = e.run(c);
      final s = run(c);
      return s.isNotEmpty && s.every((y) => y == x);
    },
    tla: '${tlaOperand(tla)} = {${e.tla}}',
    reads: reads + e.reads,
    needs: needs,
  );

  /// `S \ {e}`.
  Expr<List<E>, W> without(Expr<E, W> e) => Expr._(
    run: (c) {
      final x = e.run(c);
      return [
        for (final y in run(c))
          if (y != x) y,
      ];
    },
    tla: '${tlaOperand(tla)} \\ {${e.tla}}',
    reads: reads + e.reads,
    needs: needs,
  );

  /// `S \cup T`; [other]'s elements come last, so a set the code keeps in
  /// use order (`SiteRuntime.loaded`) takes them as its newest.
  Expr<List<E>, W> union(Expr<Iterable<E>, W> other) => Expr._(
    run: (c) {
      final t = other.run(c).toList();
      return [
        for (final e in run(c))
          if (!t.contains(e)) e,
        ...t,
      ];
    },
    tla: '${tlaOperand(tla)} \\cup ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
    needs: needs.intersection(other.needs),
  );

  /// `S \ T`, [other] a set of the model.
  Expr<List<E>, W> less(Expr<Iterable<E>, W> other) => Expr._(
    run: (c) {
      final t = other.run(c).toSet();
      return [
        for (final e in run(c))
          if (!t.contains(e)) e,
      ];
    },
    tla: '${tlaOperand(tla)} \\ ${tlaOperand(other.tla)}',
    reads: reads + other.reads,
    needs: needs,
  );

  /// S itself, in the order the code keeps it.
  Expr<List<E>, W> get inOrder => Expr._(
    run: (c) => run(c).toList(),
    tla: tla,
    reads: reads,
    needs: needs,
    literal: literal,
  );

  /// `Cardinality(S)`.
  Expr<int, W> get size => Expr._(
    run: (c) => run(c).toSet().length,
    tla: 'Cardinality(${tlaOperand(tla)})',
    reads: reads,
  );

  /// `{C \in SUBSET S : Cardinality(C) = size}`: the sets of [size] drawn
  /// from this one. The model may take any; the code takes [taken], which
  /// is asserted to be one of them, so a pick over these runs as the code's
  /// own choice.
  Expr<List<List<E>>, W> choices({
    required Expr<int, W> size,
    required List<E> Function(StepView<W> c) taken,
  }) => Expr._(
    run: (c) {
      final pick = taken(c);
      assert(() {
        final all = run(c).toSet();
        return pick.toSet().length == pick.length &&
            all.containsAll(pick) &&
            pick.length == size.run(c);
      }(), 'the code took $pick, which ${choicesTla(size)} does not offer');
      return [pick];
    },
    tla: choicesTla(size),
    reads: reads + size.reads,
  );

  String choicesTla(Expr<int, Object?> size) =>
      '{C \\in SUBSET ${tlaOperand(tla)} : Cardinality(C) = ${tlaOperand(size.tla)}}';
}
