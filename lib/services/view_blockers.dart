import 'package:meta/meta.dart' show visibleForTesting;
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';

/// What a site webview's native interceptor is told: its site, the DNS
/// level it runs at (`kDnsLevelOff` when its DNS blocking is off), whether
/// LocalCDN may serve its sub-resources (LCDN-007) and whether the filter
/// lists judge them (CB-006).
typedef SiteBlockers = ({
  SiteId site,
  int dnsLevel,
  bool localCdn,
  bool contentBlock,
});

/// A site webview whose native interceptor the app attaches, by the name
/// the plugin knows it by: a platform view's id, or a headless webview's
/// (NOTIF-016), which has no platform view.
sealed class InterceptedView {
  const InterceptedView();
}

/// A webview behind a platform view: a site's own, or a popup it opened.
final class OnPlatformView extends InterceptedView {
  const OnPlatformView(this.id);

  final Object id;

  @override
  bool operator ==(Object other) => other is OnPlatformView && other.id == id;

  @override
  int get hashCode => Object.hash(OnPlatformView, id);

  @override
  String toString() => 'platform view $id';
}

/// A background wake's headless check (NOTIF-016).
final class OnHeadless extends InterceptedView {
  const OnHeadless(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is OnHeadless && other.id == id;

  @override
  int get hashCode => Object.hash(OnHeadless, id);

  @override
  String toString() => 'headless webview $id';
}

/// A live site webview and its blockers.
typedef ViewAttach = ({InterceptedView view, SiteBlockers blockers});

/// The partition and the app-wide level in force, as the model's `dns`:
/// the app-wide level and the levels downloaded.
typedef LevelsInForce = ({int level, Set<int> levels});

/// One site webview as its native interceptor was last told (DNS-022).
final class _View {
  _View({
    required this.site,
    required this.siteLevel,
    required this.localCdn,
    required this.contentBlock,
    required this.told,
  });

  final SiteId site;

  /// The level the site asks for, as `resolveDnsLevel` takes it: null to
  /// follow the app-wide level, `kDnsLevelOff` when its DNS blocking is off.
  final int? siteLevel;
  final bool localCdn;
  final bool contentBlock;
  int told;
}

/// Which DNS level each live site webview has told its native interceptor:
/// the model's `told`, which is a site's, so a site's first view to attach
/// and its last to go are the environment's `ViewBuilt` and `ViewGone`
/// ([ViewsTable]), and another view of a site that has one joins or leaves
/// writing none of the model. A wake's headless check is one from its
/// attach to its dispose. When the blockers' data moves, every view whose
/// site now resolves to another level is told it, so a level that lands, or
/// an app-wide level the user downloads, reaches a page without a rebuild.
final class ViewBlockers {
  ViewBlockers({required this.send, required this.inForce});

  /// Sends one view its blockers; the native interceptor's attach.
  final void Function(ViewAttach attach) send;

  /// The partition and the app-wide level in force now.
  final LevelsInForce Function() inForce;

  final Map<InterceptedView, _View> _views = {};

  /// The level a site asking for [siteLevel] runs at now.
  int resolve(int? siteLevel) {
    final (:level, :levels) = inForce();
    return resolveDnsLevel(
      siteLevel: siteLevel,
      globalLevel: level,
      downloadedLevels: levels,
    );
  }

  /// [view] is built for [site] while the sites [vars] names run: it
  /// attaches at the level its site resolves to now, and is told again
  /// whenever that moves. Returns the attach its build sends. A view whose
  /// site no longer runs, a build that outlived its site's unload, attaches
  /// at that level and is told nothing more: the model builds no view for a
  /// site that does not run.
  ViewAttach built(
    InterceptedView view, {
    required SiteId site,
    required int? siteLevel,
    required bool localCdn,
    required bool contentBlock,
    required RuntimeVars<SiteId> vars,
  }) {
    final w = ViewsWorld._(
      this,
      view: view,
      site: site,
      asked: (
        siteLevel: siteLevel,
        localCdn: localCdn,
        contentBlock: contentBlock,
      ),
      vars: vars,
    );
    final c = StepContext(w);
    if (_hasView(site)) {
      _attach(w, level: resolve(siteLevel), commit: const Commit.none());
    } else if (ViewsTable.table.admits(ViewsPlace.built, on: c)) {
      ViewsTable.table.runEnvironment(c, at: ViewsPlace.built);
    } else {
      LogTag.dnsBlock.debug(
        'A view of $site attaches where its site no longer runs; nothing '
        'tells it again',
        sensitive: true,
      );
      return _attachOf(w, level: resolve(siteLevel));
    }
    return w._attached!;
  }

  /// [view] has left the tree: nothing tells it any more.
  void gone(InterceptedView view) {
    final v = _views[view];
    if (v == null) return;
    if (_views.values.where((o) => o.site == v.site).length > 1) {
      _detach(view, commit: const Commit.none());
      return;
    }
    ViewsTable.table.runEnvironment(
      StepContext(ViewsWorld._(this, view: view, site: v.site)),
      at: ViewsPlace.gone,
    );
  }

  bool _hasView(SiteId site) => _views.values.any((v) => v.site == site);

  ViewAttach _attachOf(ViewsWorld w, {required int level}) {
    final asked = w.asked!;
    return (
      view: w.view,
      blockers: (
        site: w.site,
        dnsLevel: level,
        localCdn: asked.localCdn,
        contentBlock: asked.contentBlock,
      ),
    );
  }

  /// [w]'s view joins the views told, at [level], in [commit]: its site's
  /// first view writes `told`.
  void _attach(ViewsWorld w, {required int level, required Commit commit}) {
    final asked = w.asked!;
    assert(
      level == resolve(asked.siteLevel),
      "${w.site}'s view is told DNS level $level where its site resolves to "
      '${resolve(asked.siteLevel)} (DNS-022)',
    );
    if (!_hasView(w.site)) commit.wrote(ModelVar.told);
    _views[w.view] = _View(
      site: w.site,
      siteLevel: asked.siteLevel,
      localCdn: asked.localCdn,
      contentBlock: asked.contentBlock,
      told: level,
    );
    w._attached = _attachOf(w, level: level);
  }

  /// [view] leaves the views told, in [commit]: its site's last view
  /// writes `told`.
  void _detach(InterceptedView view, {required Commit commit}) {
    final v = _views.remove(view);
    if (v != null && !_hasView(v.site)) commit.wrote(ModelVar.told);
  }

  /// The blockers' data moved: each view whose site resolves elsewhere now
  /// is told so.
  void changed() =>
      tell({for (final v in _views.values) v.site: resolve(v.siteLevel)});

  /// Each view whose site [to] names at another level than it was told is
  /// told that level, which must be the one its site resolves to: a table
  /// tells the model's level, which [resolve] recomputes from the lists in
  /// force.
  void tell(Map<SiteId, int> to) {
    for (final MapEntry(key: view, value: v) in _views.entries) {
      final now = to[v.site];
      if (now == null) continue;
      assert(
        now == resolve(v.siteLevel),
        "${v.site}'s view is told DNS level $now where its site resolves to "
        '${resolve(v.siteLevel)} (DNS-022)',
      );
      if (now == v.told) continue;
      v.told = now;
      send((
        view: view,
        blockers: (
          site: v.site,
          dnsLevel: now,
          localCdn: v.localCdn,
          contentBlock: v.contentBlock,
        ),
      ));
    }
  }

  /// The level each site's webview was last told, by site: the model's
  /// `told`, where a site with no webview is absent.
  Map<SiteId, int> get told => {for (final v in _views.values) v.site: v.told};

  /// The level each site with a webview asks for, by site.
  Map<SiteId, int?> get siteLevels => {
    for (final v in _views.values) v.site: v.siteLevel,
  };
}

/// What a view's build asks: its site's own level, as `resolveDnsLevel`
/// takes it, and the blockers it attaches with.
typedef ViewAsk = ({int? siteLevel, bool localCdn, bool contentBlock});

/// Where the environment's view steps are: no flow's places, since they
/// move none.
enum ViewsPlace { built, gone }

/// What a view step runs against: the views told, the view built or gone
/// and its site; for a build, what it asks and the page's runtime, whose
/// running sites a view is built for.
final class ViewsWorld {
  ViewsWorld._(
    this.views, {
    required this.view,
    required this.site,
    this.asked,
    this.vars,
  });

  final ViewBlockers views;
  final InterceptedView view;
  final SiteId site;
  final ViewAsk? asked;
  final RuntimeVars<SiteId>? vars;

  /// The level the step's write of `told` gives the site, which the
  /// platform's half of the write ([_land]) makes so.
  int? _told;
  ViewAttach? _attached;

  /// The view joins the views told at the level written, or leaves them at
  /// `-1`.
  void _land({required Commit commit}) => switch (_told) {
    -1 => views._detach(view, commit: commit),
    final level? => views._attach(this, level: level, commit: commit),
    null => throw StateError('no write of told landed for $site'),
  };
}

/// The environment's view steps (DNS-022): a site's first webview built
/// attaches its native interceptor at the level its site resolves to under
/// the lists in force (`ViewBuilt`), where its site runs (`Running`): a
/// frame's for a loaded site, a nested screen's, a popup either opens, a
/// wake's headless check; its last to go leaves the views told
/// (`ViewGone`). The model's `told` is a site's and a site's views run one
/// level, so another view of a site joins or leaves writing none of the
/// model ([ViewBlockers.built], [ViewBlockers.gone]).
abstract final class ViewsTable {
  static final StepTable<ViewsWorld, ViewsPlace> table = StepTable(
    ViewsPlace.values,
    vars: [_toldWhole],
    at: (place) => switch (place) {
      ViewsPlace.built => Step.environment(
        ActivationStep.viewBuilt,
        pick: _each,
        site: _each.it,
        enabled:
            _dnsLevels.isNotEmpty &
            _running.has(_each.it) &
            _told.at(_each.it).eq(_none),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [told(to: _resolved)],
          next: to(ViewsPlace.built),
        ),
      ),
      ViewsPlace.gone => Step.environment(
        ActivationStep.viewGone,
        pick: _each,
        site: _each.it,
        enabled: _told.at(_each.it).neq(_none),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [told(to: _none)],
          next: to(ViewsPlace.gone),
        ),
      ),
    },
  );

  /// The site's views told [to], `told' = [told EXCEPT ![s] = to]`, which
  /// the view's attach, or its leaving at `-1`, makes so.
  @visibleForTesting
  static Act<ViewsWorld> told({required Expr<int, ViewsWorld> to}) => Act.of([
    _told.except(_each.it, to: to),
  ], then: (c) => _world.from(c)._land(commit: c.commit));

  /// The app-wide level in force, `dns.lvl`.
  @visibleForTesting
  static final Expr<int, ViewsWorld> appWide = _dns.value.part(
    'lvl',
    get: (d) => d.level,
  );
}

/// The site whose view is built or gone, `s` in the model, any site its
/// guard admits.
final _each = Pick<SiteId, ViewsWorld>(
  Expr.ofConstant(ModelConst.sites, run: (c) => [_world.from(c).site]),
);

/// The step's world, whose view the platform's half of its write attaches
/// or drops.
final _world = Port<ViewsWorld, ViewsWorld>(
  'views',
  reads: {ModelVar.told},
  changes: {ModelVar.told},
  of: (w) => w,
);

/// `told[s]`, -1 for a site with no view; a write of it is staged in the
/// world for the view's attach or its leaving to make so.
final _told = Indexed<SiteId, int, ViewsWorld>(
  ModelVar.told,
  read: (w, {required at}) => w.views.told[at] ?? -1,
  write: (w, {required at, required to}) => w._told = to,
);

/// `told` whole: every site with a view.
final _toldWhole = Var<Map<SiteId, int>, ViewsWorld>(
  ModelVar.told,
  read: (w) => w.views.told,
);

final _none = Expr.constant<int, ViewsWorld>(-1);

/// The partition and the app-wide level in force (`dns`).
final _dns = Var<LevelsInForce, ViewsWorld>(
  ModelVar.dns,
  read: (w) => w.views.inForce(),
);

/// The level each site asks for (`SiteLevel`): the view's own ask.
final _siteLevel = Indexed<SiteId, int, ViewsWorld>.fixed(
  ModelConst.siteLevel,
  read: (w, {required at}) => w.asked?.siteLevel ?? kDnsLevelFollow,
);

/// The level a site's view runs at under the lists in force.
final _resolved = resolveLevelDef<ViewsWorld>().call([
  _siteLevel.at(_each.it),
  ViewsTable.appWide,
  _dns.value.part<Iterable<int>>('levels', get: (d) => d.levels),
]);

/// The levels a download may pick (`DnsLevels`): every level in the code.
final _dnsLevels = Constant<Iterable<int>, ViewsWorld>(
  ModelConst.dnsLevels,
  read: (_) => [for (var l = 1; l <= kDnsMaxLevel; l++) l],
).value;

/// The sites that run (`Running`): the loaded ones, a nested screen's and
/// a wake's checks.
final _running = ModelDef.running.named<Iterable<SiteId>, ViewsWorld>(
  run: (c) => _vars.from(c).running,
);
final _vars = RuntimeVars.port<SiteId, ViewsWorld>(
  reads: {ModelVar.loaded, ModelVar.nested, ModelVar.headless},
  of: (w) => w.vars!,
);
