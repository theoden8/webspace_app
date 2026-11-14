part of 'step_table.dart';

/// A turn in which the model's state may be written: the runner makes one
/// for each arm it applies, and [commitInput] for an input the code marks
/// by hand. A cell the code shares ([SharedAt]) writes only with one in
/// hand, so a write outside them does not compile.
final class Commit {
  const Commit._() : environment = null, _none = false;

  /// A write of one of the environment's actions outside a table's turn:
  /// one `activation.tla` states by hand, or the frame's build in
  /// `getWebView`, which the model takes in the step it follows.
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
  /// hands it the back stack queued for that tab, as
  /// `WebViewModel.getWebView` does it: the model takes it in the step whose
  /// commit it follows (`TabVars.framed`), or for a webview let go of in the
  /// frame table's `Reframe` (`FrameTable`). The model's layer runs no table
  /// of the page's, so the build writes in this commit, not the step's.
  frame,

  /// A built webview's controller restoring the back stack its frame took,
  /// as `WebViewModel.getWebView`'s `onControllerCreated` does it: the
  /// model's `Restored`, which the frame table's step prints and the walks
  /// mark (`FrameTable`).
  restore,

  /// A row moved to another place in the list (`Move(from, to)`).
  move,

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

/// What the model does that the code leaves to its structure: the jar's
/// turn is the SerialQueue's, held while a flow runs in the table and
/// passed on when it leaves; a witness only the model keeps.
Act<W> modelOnly<W>(
  String tla, {
  required Set<ModelVar> writes,
  required Reads reads,
}) => Act(writes: writes, tla: tla, reads: reads, run: (_) {});

/// A witness only the model keeps: [witness] met by a step that lands while
/// a flow is out. `Idle` is how the model schedules, which a footprint
/// leaves out (`formal/footprint.py`), so the witness reads only `seen`.
Act<W> midFlight<W>(String witness) => modelOnly<W>(
  "seen' = seen \\cup (IF Idle THEN {} ELSE {\"$witness\"})",
  writes: {ModelVar.seen},
  reads: const Reads(vars: {ModelVar.seen}),
);
