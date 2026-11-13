import 'package:meta/meta.dart' show visibleForTesting;
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Where the environment's frame is: no flow's place, since its step moves
/// none.
enum FramePlace { reframe }

/// What the frame's step runs against: the page's sites, the one whose
/// webview it builds, and that build as the platform makes it: a webview
/// for the site's active tab, from the back stack the frame hands it
/// ([WebViewTabBinding.frame]).
final class FrameWorld implements SiteModels {
  FrameWorld(this._sites, {required this.site, required this.build});

  final SiteRuntime _sites;
  final WebViewModel site;
  final void Function({required Commit commit}) build;

  @override
  WebViewModel siteOf(SiteId id) => _sites.siteOf(id);
}

/// The environment's frame of a loaded site whose webview was let go of (a
/// renderer gone, a setting's rebuild, a reset: `LetGo`), where the model
/// lets one be (`Rebuilt`): it builds the webview again for the active tab
/// and from the back stack queued for it, as a commit's frame does
/// (`TabVars.framed`, TAB-003). `WebViewModel.getWebView` makes the same
/// build ([WebViewTabBinding.frame]) for every frame, a commit's among
/// them, which that commit's step prints; the model's layer runs no table
/// of the page's, so it calls the build itself.
abstract final class FrameTable {
  /// The frame builds [site]'s let-go webview, by [build], as the walks
  /// run the environment.
  @visibleForTesting
  static void reframe(
    SiteRuntime sites, {
    required WebViewModel site,
    required void Function({required Commit commit}) build,
  }) => table.runEnvironment(
    StepContext(FrameWorld(sites, site: site, build: build)),
    at: FramePlace.reframe,
  );

  static final StepTable<FrameWorld, FramePlace> table = StepTable(
    FramePlace.values,
    vars: [_loaded, _current, _built, _queued],
    at: (place) => switch (place) {
      FramePlace.reframe => Step.environment(
        ActivationStep.reframe,
        pick: _each,
        site: _each.it,
        enabled:
            rebuiltOf<SiteId, FrameWorld>().has(_each.it) &
            _loaded.value.has(_each.it) &
            TabVars.tabbed<SiteId, FrameWorld>().has(_each.it) &
            TabVars.built<SiteId, FrameWorld>(
              keys: TabVars.ids(),
            ).at(_each.it).eq(noTab()),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            TabVars.framed(
              _each.it,
              keys: TabVars.ids(),
              loaded: _loaded.value,
              build: (c) => _build.from(c)(commit: c.commit),
            ),
          ],
          next: to(FramePlace.reframe),
        ),
      ),
    },
  );
}

/// The site the frame builds, `s` in the model, any site its guard admits.
final _each = Pick<SiteId, FrameWorld>(
  Expr.ofConstant(
    ModelConst.sites,
    run: (c) => [_named.from(c)],
  ),
);

/// The site the frame builds, by id.
final _named = Port<SiteId, FrameWorld>(
  'site',
  reads: const {},
  changes: const {},
  of: (w) => w.site.siteId,
);

/// The build, which the platform makes: its writes are the frame's.
final _build = Port<void Function({required Commit commit}), FrameWorld>(
  'build',
  reads: const {},
  changes: {ModelVar.built, ModelVar.hist, ModelVar.queued},
  of: (w) => w.build,
);

final _loaded = Mutable<Iterable<SiteId>, FrameWorld>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);
final _current = Mutable<SiteId?, FrameWorld>.over(
  ModelVar.current,
  of: (w) => w._sites.vars.current,
);

/// `built` and `queued` whole, as the bindings hold them, so the frame
/// check holds the build to the writes the step declares.
final _built = Var<Map<SiteId, TabId?>, FrameWorld>(
  ModelVar.built,
  read: (w) => {for (final m in w._sites.models) m.siteId: m.tabBinding.built},
);
final _queued = Var<Map<SiteId, TabId?>, FrameWorld>(
  ModelVar.queued,
  read: (w) => {
    for (final m in w._sites.models) m.siteId: m.tabBinding.queuedFor,
  },
);
