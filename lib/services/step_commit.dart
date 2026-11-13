part of 'step_table.dart';

/// A turn in which the model's state may be written: the runner makes one
/// for each arm it applies, and [commitInput] for an input the code marks
/// by hand. A cell the code shares ([SharedAt]) writes only with one in
/// hand, so a write outside them does not compile.
final class Commit {
  const Commit._() : environment = null, _none = false;

  /// A write of one of the environment's actions `activation.tla` states by
  /// hand: the model takes it there, not in a table's step.
  const Commit.environment(Environment this.environment) : _none = false;

  /// A turn that writes none of the model's state: a change to what the
  /// model does not hold, such as a site's name or its settings. A write in
  /// it fails at once.
  const Commit.none() : environment = null, _none = true;

  /// A model a test builds before any step runs.
  @visibleForTesting
  const Commit.fixture() : environment = null, _none = false;

  final Environment? environment;
  final bool _none;

  /// This commit wrote [variable].
  void wrote(ModelVar variable) {
    assert(!_none, 'a turn that writes none of the model wrote $variable');
  }
}

/// The environment's actions of `activation.tla` the code writes the
/// model's variables in, hand-written there until the tables print them.
enum Environment {
  /// The sites the last session saved, read into an empty list before any
  /// flow runs: the list `Init` starts from.
  init,

  /// The frame that builds a loaded site's webview for its active tab and
  /// hands it the back stack queued for that tab (`Frame(s)`).
  frame,

  /// A row moved to another place in the list (`Move(from, to)`).
  move,

  /// A site joining the list at its end, where the model kept its row
  /// (`Join(s)`): an add, an archive's open.
  join,

  /// A loaded site's webview let go of so the frame builds it afresh
  /// (`LetGo(s)`): a changed posture, proxy, user script, Tor binding or
  /// address, a data clear, a reset, a renderer gone (BUG-002), a move
  /// into an archive or out, onto the other tier's container.
  letGo,
}

/// An input the code marks by hand ([ActivationSteps.mark]) and what it
/// writes of the model, in one synchronous turn: [writes] runs with the
/// input's [Commit], then the step is marked.
void commitInput(
  ActivationStep step, {
  required StepOutcome outcome,
  required Object? site,
  required void Function(Commit commit) writes,
}) {
  writes(const Commit._());
  ActivationSteps.mark(step, outcome: outcome, site: site);
}

/// A variable of the model that is a function of a key (`tabs[s]`), as
/// the state that owns it keeps it: read anywhere, written only with a
/// [Commit], which a table's arm ([Indexed.over]) or a hand-marked input
/// ([commitInput]) gives; or, where
/// the model holds only a value's [members], rearranged without one.
final class SharedAt<K, V> {
  SharedAt(
    this.variable, {
    required V Function(K at) read,
    required void Function(K at, {required V to}) write,
    this.members,
  }) : _read = read,
       _write = write;

  final ModelVar variable;
  final V Function(K at) _read;
  final void Function(K at, {required V to}) _write;

  /// What the model holds of a value when it holds a set of it: `tabs[s]`
  /// is the ids of the tabs, not their order or their tree.
  final Set<Object?> Function(V value)? members;

  V of(K at) => _read(at);

  void write({required K at, required V to, required Commit commit}) {
    _write(at, to: to);
    commit.wrote(variable);
  }

  /// A write the model cannot see, so no step takes it: [to] holds the
  /// members the value holds now (a tab dragged within its tree, TAB-015).
  void rearrange({required K at, required V to}) {
    final held = members;
    assert(held != null, '${variable.name}: the model holds all of it');
    if (held != null) {
      final now = held(of(at));
      final then = held(to);
      assert(now.length == then.length && now.containsAll(then),
          '${variable.name}: a rearrangement changed what the model holds');
    }
    _write(at, to: to);
  }
}
