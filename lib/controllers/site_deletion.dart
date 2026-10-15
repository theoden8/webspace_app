import 'dart:async';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/step_flow.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/web_view_model.dart';

/// What a delete asks of the page beside its commit.
abstract interface class SiteDeletionHost implements PageHost {
  /// The next frame, which unmounts the webviews of sites no longer loaded.
  Future<void> endOfFrame();

  /// [change] in the parts the delete's steps run it in, so the lists move
  /// in the drop's turn (`SiteSetCommit.stage`).
  SiteSetStage stageSites(SiteSetChange change);
}

/// Where a delete waits.
enum DeletePlace { delete, dDrop, dFrame, dRetire, done }

/// Deleting a site (CONT-010), in the order an archive's close keeps: the
/// site leaves the lists, the loaded set, the screen and its webview in the
/// page's commit, which also closes the tabs it hosted (LIR-023) and sweeps
/// what the app kept for it; its container waits for the frame that
/// unmounts its webview, since one a mounted webview binds is not deleted.
final class SiteDeletion {
  SiteDeletion(this._sites, {required SiteDeletionHost host}) : _host = host;

  final SiteRuntime _sites;
  final SiteDeletionHost _host;

  Future<void> delete(WebViewModel site) async {
    if (!_sites.models.contains(site)) return;
    final c = StepContext(DeleteFlow._(this, site: site));
    final next = deleteTable.runInput(c, from: DeletePlace.delete);
    if (next == DeletePlace.done) return;
    await deleteTable.run(c, from: next);
  }

  static StepTable<DeleteFlow, DeletePlace> get deleteTable => _deleteTable;
}

/// What a delete's steps run against.
final class DeleteFlow {
  DeleteFlow._(this.controller, {required this.site});

  final SiteDeletion controller;
  final WebViewModel site;

  SiteRuntime get _sites => controller._sites;

  /// The page's commit of its leaving the lists.
  late final SiteSetStage _drop = controller._host.stageSites(
    SiteRemoved(site),
  );

  /// What follows the commit (the tabs it hosted, the sweep), then the
  /// frame that unmounts its webview.
  Future<void> frame() async {
    await _drop.follow();
    await controller._host.endOfFrame();
  }

  /// Its container, or on the shared jar its cookies, the session of a
  /// loaded site of its base domain kept around the delete; then its
  /// pinned shortcut.
  Future<void> retire() async {
    switch (_sites.isolation) {
      case Containers(:final engine):
        await engine.onSiteDeleted(site.containerKey);
      case SharedJar(:final jar):
        await jar.preDeleteCookieCleanup(
          deletedModel: site,
          loaded: _sites.loaded,
        );
    }
    await ShortcutService.removeShortcut(site.siteId);
  }
}

/// The site a delete names, and whether the page still lists it.
final _deleteNamed = Port<({WebViewModel site, bool Function() listed}), DeleteFlow>(
  'named',
  reads: {ModelVar.gone},
  changes: const {},
  of: (w) => (site: w.site, listed: () => w._sites.models.contains(w.site)),
);

/// The page's commit, which takes the site off the lists, the loaded set
/// and the screen and lets go of its webview (`SiteRuntime.apply`); the
/// frame that unmounts it; the platform's delete of its container.
final _deleteDropPort = Port<SiteSetStage, DeleteFlow>(
  'drop',
  reads: const {},
  changes: {
    ModelVar.gone,
    ModelVar.loaded,
    ModelVar.current,
    ModelVar.version,
    ModelVar.built,
    ModelVar.hist,
  },
  of: (w) => w._drop,
);
final _deleteFramePort = Port<Future<void> Function(), DeleteFlow>(
  'frame',
  reads: const {},
  changes: {ModelVar.views},
  of: (w) => w.frame,
);
final _deleteRetirePort = Port<Future<void> Function(), DeleteFlow>(
  'retire',
  reads: const {},
  changes: {ModelVar.boxes},
  of: (w) => w.retire,
);

final _deleteKind = Field<FlowKind, DeleteFlow>(FlowField.kind);
final _deleteSite = Field<WebViewModel, DeleteFlow>(FlowField.site);

/// The site a delete names, `s` in the model, from the listed sites a world
/// lets it delete (`Deletable`).
final _eachDeletable = Pick<WebViewModel, DeleteFlow>(
  Expr.op(
    r'Listed \cap Deletable',
    run: (c) => [_deleteNamed.from(c).site], reads: const Reads(base: {BaseOp.listed}),
    needs: const {(of: ModelConst.deletable, set: true)},
  ),
);

final _deleteLoaded = Mutable<Iterable<WebViewModel>, DeleteFlow>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);
final _deleteCurrent = Mutable<WebViewModel?, DeleteFlow>.over(
  ModelVar.current,
  of: (w) => w._sites.vars.current,
);
final _deleteVersion = Mutable<int, DeleteFlow>.over(
  ModelVar.version,
  of: (w) => w._sites.vars.version,
);
final _deleteGone = Mutable<Iterable<WebViewModel>, DeleteFlow>.remote(
  ModelVar.gone,
);
final _deleteViews = Mutable<Iterable<WebViewModel>, DeleteFlow>.remote(
  ModelVar.views,
);
final _deleteBoxes = Mutable<Iterable<WebViewModel>, DeleteFlow>.remote(
  ModelVar.boxes,
);
final _deleteNoSite = Expr.constant<WebViewModel?, DeleteFlow>(null, tla: '0');

/// Another delete of the site took it off the list first.
final _deleteAlreadyGone = Expr.op<bool, DeleteFlow>(
  '${_deleteSite.value.tla} \\in gone',
  run: (c) => !_deleteNamed.from(c).listed(),
  reads: _deleteSite.value.reads + const Reads(vars: {ModelVar.gone}),
);
final _deleteDone = GoTo<DeleteFlow, DeletePlace>(to(DeletePlace.done));

/// Its container, unless a mounted webview still binds it.
final _deleteRetire = Await<DeleteFlow, DeletePlace>(
  ActivationStep.deleteRetireReply,
  at: DeletePlace.dRetire,
  holds: null,
  call: Call.on(
    _deleteRetirePort,
    run: (c) => c.api(),
    writes: [
      _deleteBoxes.becomes(
        _deleteBoxes.value.less(
          _deleteSite.value.asSet.less(_deleteViews.value),
        ),
      ),
    ],
  ),
  decide: Ends(StepOutcome.none, next: _deleteDone),
);

/// The frame unmounts its webview.
final _deleteFrame = Await<DeleteFlow, DeletePlace>(
  ActivationStep.deleteFrameReply,
  at: DeletePlace.dFrame,
  holds: null,
  call: Call.on(
    _deleteFramePort,
    run: (c) => c.api(),
    writes: [
      _deleteViews.becomes(_deleteViews.value.less(_deleteSite.value.asSet)),
    ],
  ),
  decide: Ends(StepOutcome.none, next: _deleteRetire),
);

/// The page's commit takes the site off the lists, the loaded set and the
/// screen, lets go of its webview, and bumps the version, unless another
/// delete of it already did.
final _deleteDrop = Await<DeleteFlow, DeletePlace>(
  ActivationStep.deleteDropReply,
  at: DeletePlace.dDrop,
  holds: null,
  call: Call.on(
    _deleteDropPort,
    run: (c) => c.api.prepare(),
    then: (c) => _deleteDropPort.from(c).land(commit: c.commit),
    writes: [
      _deleteGone.becomes(_deleteGone.value.union(_deleteSite.value.asSet)),
      _deleteLoaded.becomes(_deleteLoaded.value.less(_deleteSite.value.asSet)),
      _deleteCurrent.becomes(
        Expr.choose(
          when: _deleteSite.value.asSet.has(_deleteCurrent.value),
          then: _deleteNoSite,
          otherwise: _deleteCurrent.value,
        ),
      ),
      _deleteVersion.becomes(
        Expr.choose(
          when: _deleteAlreadyGone,
          then: _deleteVersion.value,
          otherwise: _deleteVersion.value.plus(1),
        ),
      ),
      ...webViewGone(_deleteSite.value),
    ],
  ),
  decide: Ends(StepOutcome.none, next: _deleteFrame),
);

final _deleteFlow = FlowInput<DeleteFlow, DeletePlace>(
  ActivationStep.deleteSite,
  at: DeletePlace.delete,
  pick: _eachDeletable,
  decide: Ends(
    StepOutcome.none,
    does: [
      _deleteKind.becomes(Expr.constant(FlowKind.delete)),
      _deleteSite.becomes(_eachDeletable.it),
    ],
    next: _deleteDrop,
  ),
);

final _deleteSteps = _deleteFlow.steps;

final StepTable<DeleteFlow, DeletePlace> _deleteTable = StepTable(
  DeletePlace.values,
  ending: {DeletePlace.done},
  vars: [_deleteLoaded, _deleteCurrent, _deleteVersion],
  at: (place) => switch (place) {
    DeletePlace.delete ||
    DeletePlace.dDrop ||
    DeletePlace.dFrame ||
    DeletePlace.dRetire => _deleteSteps[place]!,
    DeletePlace.done => const Leaves(),
  },
);
