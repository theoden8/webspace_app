import 'package:meta/meta.dart';
import 'package:webspace/services/step_table.dart';

/// The activation in flight: its target and the version it began at.
typedef ActivationMarker<S extends Object> = ({S target, int version});

/// The model's variables the page's runtime owns, as the tables write them
/// (`Mutable.over`): the loaded sites, the site on screen, the version its
/// inputs count, the marker of the activation in flight, the site whose
/// nested screen is up and the sites a wake checks headless, over sites of
/// type [S], which only identity is asked of. The model's operators over
/// these alone are defined here, so each rule runs where its variables are
/// and prints from the same tree (`activation_ops`).
final class RuntimeVars<S extends Object> {
  RuntimeVars({
    required this.loaded,
    required this.current,
    required this.version,
    required this.marker,
    required this.nested,
    required this.headless,
    required this.fore,
  });

  /// A page that keeps the loaded sites as a set and the rest as plain
  /// values: a test's host.
  @visibleForTesting
  factory RuntimeVars.ofSet(Set<S> loaded, {S? shown, bool onScreen = true}) {
    var current = shown;
    var version = 0;
    ActivationMarker<S>? marker;
    S? nested;
    final headless = <S>{};
    var fore = onScreen;
    return RuntimeVars(
      loaded: Shared.ofSet(loaded, variable: ModelVar.loaded),
      current: Shared(ModelVar.current, read: () => current, write: (to) => current = to),
      version: Shared(ModelVar.version, read: () => version, write: (to) => version = to),
      marker: Shared(ModelVar.marker, read: () => marker, write: (to) => marker = to),
      nested: Shared(ModelVar.nested, read: () => nested, write: (to) => nested = to),
      headless: Shared.ofSet(headless, variable: ModelVar.headless),
      fore: Shared(ModelVar.fore, read: () => fore, write: (to) => fore = to),
    );
  }

  final Shared<Iterable<S>> loaded;
  final Shared<S?> current;
  final Shared<int> version;
  final Shared<ActivationMarker<S>?> marker;
  final Shared<S?> nested;
  final Shared<Iterable<S>> headless;

  /// Whether the app is on screen: the wake's table writes it as the app's
  /// lifecycle reports it.
  final Shared<bool> fore;

  /// The sites whose traffic runs now: the loaded ones, the one a nested
  /// screen runs as and the ones a wake checks headless, which the proxy
  /// rules range over.
  static Def<Iterable<S>, RuntimeVars<S>> runningSites<S extends Object>() {
    final loaded = Var<Iterable<S>, RuntimeVars<S>>(
      ModelVar.loaded,
      read: (w) => w.loaded.value,
    );
    final nested = Var<S?, RuntimeVars<S>>(
      ModelVar.nested,
      read: (w) => w.nested.value,
    );
    final headless = Var<Iterable<S>, RuntimeVars<S>>(
      ModelVar.headless,
      read: (w) => w.headless.value,
    );
    return Def(
      ModelDef.running,
      params: const [],
      body: loaded.value.union(nested.value.orNone).union(headless.value),
    );
  }

  late final _running = runningSites<S>();

  Set<S> get running => _running.value.run(StepContext(this)).toSet();

  /// A site an unload may take: not the one on screen, nor the target of
  /// the activation in flight (PAUSE-006, CONT-003).
  static Def<bool, RuntimeVars<S>> evictable<S extends Object>() {
    final current = Var<S?, RuntimeVars<S>>(
      ModelVar.current,
      read: (w) => w.current.value,
    );
    final marker = Var<ActivationMarker<S>?, RuntimeVars<S>>(
      ModelVar.marker,
      read: (w) => w.marker.value,
    );
    final s = Bound<S?, RuntimeVars<S>>('s');
    return Def(
      ModelDef.evictable,
      params: [s],
      body:
          s.it.neq(current.value) &
          s.it.neq(marker.value.part('t', get: (m) => m?.target)),
    );
  }

  late final _evictable = evictable<S>();

  bool isEvictable(S site) => _evictable.evaluate(this, args: [site]);

  /// These variables as a table reaches them through its world, for an
  /// operator of the model's own run by name ([Expr.op]): a read, so the
  /// port changes nothing.
  static Port<RuntimeVars<S>, W> port<S extends Object, W>({
    required Set<ModelVar> reads,
    required RuntimeVars<S> Function(W world) of,
  }) => Port('vars', reads: reads, changes: const {}, of: of);

  /// The target of the live activation: the marker's, unless an input since
  /// superseded it (the model's `LiveTarget`, read off the marker).
  S? get liveTarget => switch (marker.value) {
    final m? when m.version == version.value => m.target,
    _ => null,
  };
}
