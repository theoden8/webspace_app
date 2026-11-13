import 'dart:async';

import 'package:webspace/controllers/container_retire.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/step_flow.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// What an import asks of the page beside its steps.
abstract interface class SiteImportHost implements PageHost {
  /// The next frame, which unmounts the webviews of sites no longer loaded.
  Future<void> endOfFrame();

  /// [drop] in the parts the import's steps run it in, so the lists move in
  /// the landing's turn (`SiteSetCommit.stage`).
  SiteSetStage stageSites(SiteDrop drop);
}

/// Where an import waits.
enum ImportPlace {
  importSites,
  iTurn,
  iSnap,
  iSave,
  iNuke,
  iLandTurn,
  iLand,
  iFrame,
  iRetire,
  done,
}

/// A settings import's replacement of the sites (BACKUP-003): a site the
/// backup carries again, by id, stays on the list with its container and
/// its own session, the backup's cookies seed only the sites it brings
/// new, and every other listed site leaves. On the shared jar the import
/// first waits for the jar's turn, saves the share of each loaded site it
/// carries again and empties the jar, and lands in that turn (ISO-015); a
/// site it drops loses its webview with the next frame, then its container
/// (CONT-010).
final class SiteImport {
  SiteImport(this._sites, {required SiteImportHost host}) : _host = host;

  final SiteRuntime _sites;
  final SiteImportHost _host;

  /// Replaces the lists with [replacement]'s; false, changing nothing,
  /// while another import runs.
  Future<bool> replace(SitesReplaced replacement) async {
    final c = StepContext(ImportFlow._(this, replacement: replacement));
    if (!importTable.admits(ImportPlace.importSites, on: c)) return false;
    final next = importTable.runInput(c, from: ImportPlace.importSites);
    _running = true;
    try {
      await importTable.run(c, from: next);
    } finally {
      _running = false;
    }
    return true;
  }

  /// Whether an import is under way: the model's `"import" \in Kinds`.
  bool _running = false;

  /// The tables an import runs from, printed into the model: its own
  /// steps, and those it takes in the jar's turn.
  static StepTable<ImportFlow, ImportPlace> get importTable => _importTable;
  static StepTable<ImportFlow, ImportPlace> get turnTable => _turnTable;
}

/// What an import's steps run against: on the shared jar, the jar's turn
/// too.
final class ImportFlow extends JarWorld implements SiteModels {
  ImportFlow._(this.controller, {required this.replacement});

  final SiteImport controller;
  final SitesReplaced replacement;

  SiteRuntime get _sites => controller._sites;

  @override
  CookieIsolationEngine get engine => switch (_sites.isolation) {
    SharedJar(:final jar) => jar,
    Containers() => throw StateError('an import on containers takes no turn'),
  };

  @override
  RuntimeVars<SiteId> get vars => _sites.vars;

  @override
  SiteModels get sites => this;

  /// A listed or held site, else one the import replaced.
  @override
  WebViewModel siteOf(SiteId id) =>
      _sites.find(id) ?? _replaced.firstWhere((m) => m.siteId == id);

  /// The page's commit of the replacement.
  late final SiteSetStage _stage = controller._host.stageSites(replacement);

  /// The sites listed as the import landed, which it replaced, and those
  /// of them it took off the list, whose containers go once the frame has
  /// unmounted their webviews.
  List<WebViewModel> _replaced = const [];
  List<WebViewModel> _dropped = const [];

  Future<void> prepare() => _stage.prepare();

  /// A site carried again keeps the session it has, which on the shared
  /// jar its share just saved, not the backup's (BACKUP-003); then the
  /// lists move.
  void land({required Commit commit}) {
    _replaced = List.of(_sites.models);
    _dropped = [
      for (final m in _replaced)
        if (!replacement.sites.hasKey(m)) m,
    ];
    for (final m in replacement.sites) {
      final row = _replaced.indexOfKey(m);
      if (row >= 0) m.cookies = List.of(_replaced[row].cookies);
    }
    _stage.land(commit: commit);
  }

  /// What follows the commit, then the frame that unmounts the webviews of
  /// sites no longer loaded.
  Future<void> frame() async {
    await _stage.follow();
    await controller._host.endOfFrame();
  }

  /// The containers of the sites it dropped: one a mounted webview still
  /// binds is not deleted (LIR-023), so this waits for the frame.
  Future<void> retire() async {
    if (_sites.isolation case Containers(:final engine)) {
      for (final m in _dropped) {
        await engine.onSiteDeleted(m.containerKey);
      }
    }
  }
}

/// The page's commit, which replaces the lists, empties the loaded set and
/// the screen and lets go of every replaced webview (`SiteRuntime.apply`);
/// the frame that unmounts them; the platform's delete of the dropped
/// sites' containers.
final _landPort = Port<ImportLanding, ImportFlow>(
  'land',
  reads: const {},
  changes: {
    ModelVar.gone,
    ModelVar.loaded,
    ModelVar.current,
    ModelVar.version,
    ModelVar.tier,
    ModelVar.signedIn,
    ModelVar.built,
    ModelVar.hist,
    ModelVar.opener,
    ModelVar.link,
  },
  of: (w) => (prepare: w.prepare, land: w.land),
);

/// The import's commit as its landing steps reach it ([_landPort]).
typedef ImportLanding = ({
  Future<void> Function() prepare,
  void Function({required Commit commit}) land,
});
final _framePort = Port<Future<void> Function(), ImportFlow>(
  'frame',
  reads: const {},
  changes: {ModelVar.views},
  of: (w) => w.frame,
);
final _retirePort = Port<Future<void> Function(), ImportFlow>(
  'retire',
  reads: const {},
  changes: {ModelVar.boxes},
  of: (w) => w.retire,
);

/// The sites listed as the import landed, and those it dropped.
final _page =
    Port<({List<WebViewModel> listed, List<WebViewModel> dropped}), ImportFlow>(
      'page',
      reads: {ModelVar.gone},
      changes: const {},
      of: (w) => (listed: w._replaced, dropped: w._dropped),
    );

/// Whether an import runs.
final _runs = Port<bool Function(), ImportFlow>(
  'runs',
  reads: {ModelVar.fl},
  changes: const {},
  of: (w) => () => w.controller._running,
);

/// The jar's turn as the import takes it.
final _turn = Port<({CookieIsolationEngine jar, ImportFlow world}), ImportFlow>(
  'turn',
  reads: const {},
  changes: const {},
  of: (w) => (jar: w.engine, world: w),
);

final _importKind = Field<FlowKind, ImportFlow>(FlowField.kind);
final _dropped = Field<Iterable<SiteId>, ImportFlow>(FlowField.dropped);
final _ls = Field<List<SiteId>, ImportFlow>(FlowField.ls);

final _containers = Constant<bool, ImportFlow>(
  ModelConst.containers,
  read: (w) => w._sites.useContainers,
).value;

/// Every site the model names (`Sites`), as the page knows them: listed.
final _sitesAll = Constant<Iterable<SiteId>, ImportFlow>(
  ModelConst.sites,
  read: (w) => [for (final m in w._sites.models) m.siteId],
).value;

/// The sites the backup carries, the model's `Importing`.
final _importing = Constant<Iterable<SiteId>, ImportFlow>(
  ModelConst.importing,
  read: (w) => [for (final m in w.replacement.sites) m.siteId],
).value;

/// Whether the world imports a backup: the code may import one any time,
/// an empty one too.
final _imports = Expr.ofConstant<bool, ImportFlow>(
  ModelConst.imports,
  run: (_) => true,
);

final _listed = Expr.op<Iterable<SiteId>, ImportFlow>(
  HandPaired.importListed,
  tla: 'Listed',
  run: (c) => [for (final m in _page.from(c).listed) m.siteId],
  reads: const Reads(base: {BaseOp.listed}),
);
final _running = Expr.inFlight<ImportFlow>(
  FlowKind.import,
  run: (c) => _runs.from(c)(),
);

final _importLoaded = Mutable<Iterable<SiteId>, ImportFlow>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);
final _importCurrent = Mutable<SiteId?, ImportFlow>.over(
  ModelVar.current,
  of: (w) => w._sites.vars.current,
);
final _importVersion = Mutable<int, ImportFlow>.over(
  ModelVar.version,
  of: (w) => w._sites.vars.version,
);
final _importGone = Mutable<Iterable<SiteId>, ImportFlow>.remote(
  ModelVar.gone,
);
final _importViews = Mutable<Iterable<SiteId>, ImportFlow>.remote(
  ModelVar.views,
);
final _importBoxes = Mutable<Iterable<SiteId>, ImportFlow>.remote(
  ModelVar.boxes,
);
final _signedIn = Mutable<Iterable<SiteId>, ImportFlow>.remote(
  ModelVar.signedIn,
);
final _noSite = Expr.constant<SiteId?, ImportFlow>(null, tla: '0');

final _done = GoTo<ImportFlow, ImportPlace>(to(ImportPlace.done));

/// The dropped sites' containers, unless a mounted webview still binds one.
final _retire = retireContainers<SiteId, ImportFlow, ImportPlace>(
  ActivationStep.importRetireReply,
  at: ImportPlace.iRetire,
  port: _retirePort,
  sites: _dropped.value,
  boxes: _importBoxes,
  views: _importViews,
  next: _done,
);

/// The frame unmounts every webview whose site is not loaded, the replaced
/// ones among them.
final _frame = Await<ImportFlow, ImportPlace>(
  ActivationStep.importFrameReply,
  at: ImportPlace.iFrame,
  holds: null,
  call: Call.on(
    _framePort,
    run: (c) => c.api(),
    writes: [
      _importViews.becomes(
        _importViews.value.less(_importViews.value.less(_importLoaded.value)),
      ),
    ],
  ),
  decide: Ends(StepOutcome.none, next: _retire),
);

/// The landing: the backup's sites replace the list, the loaded set and
/// the screen empty, every replaced webview goes, a carried site is a new
/// model at the first tier, and the version moves. A site it brings onto
/// the list starts signed out: whatever session it had left with it, and
/// the backup's cookies are all it has (BACKUP-003).
List<Write<ImportFlow>> _landWrites() => [
  _importGone.becomes(_sitesAll.less(_importing)),
  _signedIn.becomes(_signedIn.value.less(_importing.less(_listed))),
  _importLoaded.becomes(Expr.none()),
  _importCurrent.becomes(_noSite),
  _importVersion.becomes(_importVersion.value.plus(1)),
  tierOf<ImportFlow>().exceptEach(
    _importing,
    x: Bound('s'),
    to: Expr.constant(SiteLifecycleState.resident, tla: '"resident"'),
  ),
  ...webViewsGone(_listed),
  ...TabVars.openersGone(_listed.less(_importing)),
];

Call<ImportFlow> _landCall() => Call.on(
  _landPort,
  run: (c) => c.api.prepare(),
  then: (c) => _landPort.from(c).land(commit: c.commit),
  writes: _landWrites(),
);

final _dropping = _dropped.becomes(
  Expr.checked(
    rule: _listed.less(_importing),
    run: (c) => [for (final m in _page.from(c).dropped) m.siteId],
    key: (id) => id,
    why: 'the import retires the listed sites the backup does not carry '
        '(CONT-010)',
  ),
);

/// On containers the import lands at once.
final _land = Await<ImportFlow, ImportPlace>(
  ActivationStep.importLandReply,
  at: ImportPlace.iLand,
  holds: null,
  call: _landCall(),
  decide: Ends(StepOutcome.none, does: [_dropping], next: _frame),
);

final _importFlow = FlowInput<ImportFlow, ImportPlace>(
  ActivationStep.importSites,
  at: ImportPlace.importSites,
  enabled: _imports & ~_running,
  decide: When(
    _containers,
    then: Ends(
      StepOutcome.go,
      does: [_importKind.becomes(Expr.constant(FlowKind.import))],
      next: _land,
    ),
    otherwise: Ends(
      StepOutcome.queued,
      does: [
        _importKind.becomes(Expr.constant(FlowKind.import)),
        Lock.jar.enqueue(),
      ],
      next: GoTo(to(ImportPlace.iTurn)),
    ),
  ),
);

final _importSteps = _importFlow.steps;

/// The steps from the jar's turn to the landing, in that turn.
Future<ImportPlace> _inTurn(
  StepView<ImportFlow> c, {
  required ImportPlace from,
}) {
  final (:jar, :world) = _turn.from(c);
  final flow = StepContext.sharing(c, world: world);
  return jar.inTurn(flow, run: () => _turnTable.run(flow, from: from));
}

final StepTable<ImportFlow, ImportPlace> _importTable = StepTable(
  ImportPlace.values,
  ending: {ImportPlace.done},
  vars: [_importLoaded, _importCurrent, _importVersion],
  at: (place) => switch (place) {
    ImportPlace.importSites ||
    ImportPlace.iLand ||
    ImportPlace.iFrame ||
    ImportPlace.iRetire => _importSteps[place]!,
    ImportPlace.iTurn ||
    ImportPlace.iSnap ||
    ImportPlace.iSave ||
    ImportPlace.iNuke ||
    ImportPlace.iLandTurn => const Within(_inTurn),
    ImportPlace.done => const Leaves(),
  },
);

/// The loaded sites the backup carries again, whose shares are saved.
final _carriedLoaded = () {
  final l = Bound<SiteId, ImportFlow>('l');
  return _importLoaded.value.where(l, holds: _importing.has(l.it));
}();

/// A refusal of the jar: what it held stays unsaved, and the import goes
/// on to empty it and land (ISO-014).
Refused<ImportFlow, ImportPlace> _refused({required ImportPlace next}) =>
    Refused(
      refusal: CookieIsolationEngine.jarRefusal,
      when: Expr.ofConstant(ModelConst.jarRefuses, run: (_) => true),
      then: [_ls.becomes(Expr.none())],
      next: to(next),
    );

final _shares = CookieIsolationEngine.shareSteps<ImportFlow, ImportPlace>(
  marks: (
    snap: ActivationStep.importSnapReply,
    save: ActivationStep.importSaveReply,
  ),
  save: ImportPlace.iSave,
  nuke: ImportPlace.iNuke,
  urlsOf: (c) => _ls.of(c),
  stale: null,
  refused: _refused(next: ImportPlace.iNuke),
);

final StepTable<ImportFlow, ImportPlace> _turnTable = StepTable(
  ImportPlace.values,
  vars: [_importLoaded, _importCurrent, _importVersion],
  at: (place) => switch (place) {
    ImportPlace.iTurn => Step(
      ActivationStep.grantImport,
      holds: null,
      granted: Lock.jar,
      otherwise: Otherwise(
        StepOutcome.snap,
        then: [Lock.jar.takeTurn(), _ls.becomes(_carriedLoaded.inOrder)],
        next: to(ImportPlace.iSnap),
      ),
    ),
    ImportPlace.iSnap => _shares.snap,
    ImportPlace.iSave => _shares.save,
    ImportPlace.iNuke => CookieIsolationEngine.nukeStep(
      ActivationStep.importNukeReply,
      next: ImportPlace.iLandTurn,
      refused: _refused(next: ImportPlace.iLandTurn),
    ),
    ImportPlace.iLandTurn => Step(
      ActivationStep.importLandTurnReply,
      holds: CookieIsolationEngine.holdsTurn(),
      call: _landCall(),
      otherwise: Otherwise(
        StepOutcome.none,
        then: [
          _dropping,
          _ls.becomes(Expr.none()),
          _snapNone,
          _todoNone,
          Lock.jar.release(),
        ],
        next: to(ImportPlace.iFrame),
      ),
    ),
    ImportPlace.importSites ||
    ImportPlace.iLand ||
    ImportPlace.iFrame ||
    ImportPlace.iRetire ||
    ImportPlace.done => const Leaves(),
  },
);

final _snapNone = Field<List<Cookie>, ImportFlow>(
  FlowField.snap,
).becomes(Expr.none());
final _todoNone = Field<List<SiteId>, ImportFlow>(
  FlowField.todo,
).becomes(Expr.none());
