import 'package:meta/meta.dart' show visibleForTesting;
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Where the environment's frame is: no flow's place, since its steps move
/// none.
enum FramePlace { reframe, restored }

/// What the frame's steps run against: the page's sites, the one whose
/// webview it builds or whose controller came, and what the platform does
/// there: the build, a webview for the site's active tab from the back
/// stack the frame hands it ([WebViewTabBinding.frame]), or the controller
/// restoring what that build took ([WebViewTabBinding.restore]).
final class FrameWorld implements SiteModels {
  FrameWorld(this._sites, {required this.site, required this.platform});

  final SiteRuntime _sites;
  final WebViewModel site;
  final void Function({required Commit commit}) platform;

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
/// of the page's, so it calls the build itself. Where a let-go may land
/// before a build's controller comes, the back stack the build took is
/// held until that controller restores it (`Restored`), and a let-go
/// before then queues it again (`LetGoTable`).
abstract final class FrameTable {
  /// The frame builds [site]'s let-go webview, by [build], as the walks
  /// run the environment.
  @visibleForTesting
  static void reframe(
    SiteRuntime sites, {
    required WebViewModel site,
    required void Function({required Commit commit}) build,
  }) => table.runEnvironment(
    StepContext(FrameWorld(sites, site: site, platform: build)),
    at: FramePlace.reframe,
  );

  /// [site]'s controller came and restores what its build held, by
  /// [restore], as the walks run the environment.
  @visibleForTesting
  static void restored(
    SiteRuntime sites, {
    required WebViewModel site,
    required void Function({required Commit commit}) restore,
  }) => table.runEnvironment(
    StepContext(FrameWorld(sites, site: site, platform: restore)),
    at: FramePlace.restored,
  );

  static final StepTable<FrameWorld, FramePlace> table = StepTable(
    FramePlace.values,
    vars: [_loaded, _current, _built, _queued, _held],
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
      FramePlace.restored => Step.environment(
        ActivationStep.restored,
        pick: _each,
        site: _each.it,
        // A site whose tabs the model does not follow holds nothing there,
        // and its controller's restore changes none of the model.
        enabled:
            rebuiltOf<SiteId, FrameWorld>().has(_each.it) &
            (~_followed | _heldAt.neq(noQueued())),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of(
              [
                TabVars.held<SiteId, FrameWorld>().becomes(
                  Expr.choose(
                    when: _followed,
                    then: TabVars.held<SiteId, FrameWorld>().value.except(
                      _each.it,
                      to: noQueued(),
                    ),
                    otherwise: TabVars.held<SiteId, FrameWorld>().value,
                  ),
                ),
              ],
              then: (c) => _restore.from(c)(commit: c.commit),
            ),
          ],
          next: to(FramePlace.restored),
        ),
      ),
    },
  );
}

/// The site the frame builds or whose controller came, `s` in the model,
/// any site its guard admits.
final _each = Pick<SiteId, FrameWorld>(
  Expr.ofConstant(
    ModelConst.sites,
    run: (c) => [_named.from(c)],
  ),
);

/// The site the step names, by id.
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
  changes: {ModelVar.built, ModelVar.hist, ModelVar.queued, ModelVar.held},
  of: (w) => w.platform,
);

/// The controller's restore, which the platform calls as it creates it:
/// what its build held goes.
final _restore = Port<void Function({required Commit commit}), FrameWorld>(
  'restore',
  reads: const {},
  changes: {ModelVar.held},
  of: (w) => w.platform,
);

/// Whether the model follows the tabs of the site the step names.
final _followed = TabVars.tabbed<SiteId, FrameWorld>().has(_each.it);

/// `held[s]`: what the site's live build took that no controller restored.
final _heldAt = TabVars.heldAt<SiteId, FrameWorld>(
  keys: TabVars.ids(),
).at(_each.it);

final _loaded = Mutable<Iterable<SiteId>, FrameWorld>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);
final _current = Mutable<SiteId?, FrameWorld>.over(
  ModelVar.current,
  of: (w) => w._sites.vars.current,
);

/// `built`, `queued` and `held` whole, as the bindings hold them, so the
/// frame check holds the build to the writes the step declares.
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
final _held = Var<Map<SiteId, TabId?>, FrameWorld>(
  ModelVar.held,
  read: (w) => {
    for (final m in w._sites.models) m.siteId: m.tabBinding.held?.tab,
  },
);
