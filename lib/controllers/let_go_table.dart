import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Where the environment's let-go is: no flow's place, since its step
/// moves none.
enum LetGoPlace { letGo }

/// What the let-go runs against: the page's sites, the one whose webview
/// goes and how that webview ended.
final class LetGoWorld implements SiteModels {
  LetGoWorld(this._sites, {required this.site, required this.end});

  final SiteRuntime _sites;
  final WebViewModel site;
  final WebViewEnd end;

  @override
  WebViewModel siteOf(SiteId id) => _sites.siteOf(id);
}

/// The environment's let-go of a site's webview so the frame builds it
/// afresh (`LetGo`): a changed posture, proxy, user script, Tor binding or
/// address, a data clear, a reset, a renderer gone (BUG-002), a move into
/// an archive or out. Where the model lets one go (a loaded site with a
/// webview built, `Rebuilt`) the step writes `built` and `hist` as the
/// model does: the history goes, the site stays loaded and its view keeps
/// its container and its DNS level; a back stack its build took that no
/// controller restored yet is queued again for its tab, so the next frame
/// shows it (TAB-003). Anywhere else (a site not loaded, or
/// one whose webview is already gone) the webview's teardown runs in a
/// turn that writes none of the model, which [Commit.none] asserts, and no
/// step is taken.
abstract final class LetGoTable {
  /// Lets go of [site]'s webview, which ended as [end]: the one way a
  /// site's webview goes for a rebuild.
  static void letGo(
    SiteRuntime sites, {
    required WebViewModel site,
    WebViewEnd end = WebViewEnd.live,
  }) {
    final c = StepContext(LetGoWorld(sites, site: site, end: end));
    if (table.admits(LetGoPlace.letGo, on: c)) {
      table.runEnvironment(c, at: LetGoPlace.letGo);
    } else {
      site.disposeWebView(commit: const Commit.none(), end: end);
    }
  }

  static final StepTable<LetGoWorld, LetGoPlace> table = StepTable(
    LetGoPlace.values,
    vars: [_loaded, _current, _built, _queued, _held],
    at: (place) => switch (place) {
      LetGoPlace.letGo => Step.environment(
        ActivationStep.letGo,
        pick: _each,
        site: _each.it,
        enabled:
            rebuiltOf<SiteId, LetGoWorld>().has(_each.it) &
            _loaded.value.has(_each.it) &
            TabVars.tabbed<SiteId, LetGoWorld>().has(_each.it) &
            TabVars.built<SiteId, LetGoWorld>(
              keys: TabVars.ids(),
            ).at(_each.it).neq(noTab()),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of(
              [...webViewGone<SiteId, LetGoWorld>(_each.it), requeued],
              then: (c) => _sites
                  .from(c)
                  .siteOf(_named.from(c))
                  .letGoWebView(commit: c.commit, end: _end.from(c)),
            ),
          ],
          next: to(LetGoPlace.letGo),
        ),
      ),
    },
  );

  /// A back stack the let-go webview's build took that no controller
  /// restored, queued again for its tab (TAB-003): the next frame shows it.
  static final Write<LetGoWorld> requeued = TabVars.queued<SiteId, LetGoWorld>()
      .becomes(
        Expr.choose(
          when: _heldAt.neq(noQueued()),
          then: TabVars.queued<SiteId, LetGoWorld>().value.except(
            _each.it,
            to: _heldAt,
          ),
          otherwise: TabVars.queued<SiteId, LetGoWorld>().value,
        ),
      );
}

/// `held[s]`: what the let-go webview's build took.
final _heldAt = TabVars.held<SiteId, LetGoWorld>().value.at(_each.it);

/// The site let go of, `s` in the model, any site its guard admits.
final _each = Pick<SiteId, LetGoWorld>(
  Expr.ofConstant(
    ModelConst.sites,
    run: (c) => [_named.from(c)],
  ),
);

/// The site let go of, by id.
final _named = Port<SiteId, LetGoWorld>(
  'site',
  reads: const {},
  changes: const {},
  of: (w) => w.site.siteId,
);

/// Where the step finds the site it lets go of, whose webview's teardown
/// is the platform's half of its writes.
final _sites = Port<SiteModels, LetGoWorld>(
  'sites',
  reads: const {},
  changes: const {},
  of: (w) => w,
);

/// How the webview ended, which decides how its teardown leaves its route.
final _end = Port<WebViewEnd, LetGoWorld>(
  'end',
  reads: const {},
  changes: const {},
  of: (w) => w.end,
);

final _loaded = Mutable<Iterable<SiteId>, LetGoWorld>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);
final _current = Mutable<SiteId?, LetGoWorld>.over(
  ModelVar.current,
  of: (w) => w._sites.vars.current,
);

/// `built`, `queued` and `held` whole, as the bindings hold them, so the
/// frame check holds the teardown to the writes the step declares.
final _built = Var<Map<SiteId, TabId?>, LetGoWorld>(
  ModelVar.built,
  read: (w) => {for (final m in w._sites.models) m.siteId: m.tabBinding.built},
);
final _queued = Var<Map<SiteId, TabId?>, LetGoWorld>(
  ModelVar.queued,
  read: (w) => {
    for (final m in w._sites.models) m.siteId: m.tabBinding.queuedFor,
  },
);
final _held = Var<Map<SiteId, TabId?>, LetGoWorld>(
  ModelVar.held,
  read: (w) => {
    for (final m in w._sites.models) m.siteId: m.tabBinding.held?.tab,
  },
);
