import 'dart:async';
import 'package:webspace/controllers/activation_flow.dart';
import 'package:webspace/controllers/activation_place.dart';
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_refused.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_flow.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';

/// The activation's step table: every place an activation, a preload, a
/// memory-pressure plan, a nested open and a webspace switch can be at,
/// the leaves its guards and writes read, and the definitions it owns.
/// [SiteActivationController] runs it; the printer prints it.
abstract final class ActivationTable {
  static const kind = Field<FlowKind, ActivationFlow>(FlowField.kind);
  static const _site = Field<WebViewModel, ActivationFlow>(FlowField.site);
  static const _v = Field<int, ActivationFlow>(FlowField.v);

  /// The jar refused a call of the flow's restore, so its target is not
  /// shown (ISO-014).
  static const unrestored = Field<bool, ActivationFlow>(FlowField.unrestored);
  static const _victims = Field<List<WebViewModel>, ActivationFlow>(FlowField.victims);
  static const _clears = Field<List<WebViewModel>, ActivationFlow>(FlowField.clears);
  static const _picked = Field<List<WebViewModel>, ActivationFlow>(FlowField.picked);
  static Expr<bool, ActivationFlow> _is(FlowKind k) => kind.isKind(k);

  /// The activation was superseded by a newer input. A preload's version is
  /// the one it read; a pressure plan reads no place that asks.
  static final _stale = _v.value.neq(_version.value);

  /// The activation, nested open or webspace switch that made an unload's
  /// plan was superseded, so the unload backs off before its dispose
  /// (`SiteUnloadEngine.spare`); a preload's or a pressure plan's unload
  /// never is.
  static final stale = Def<bool, ActivationFlow>.ofFlow(
    ModelDef.stale,
    body: (_shows | _is(FlowKind.space)) & _stale,
  );

  /// A flow that takes the screen: an activation, or a nested open, which
  /// may unload the site on screen.
  static final _shows = _is(FlowKind.tap) | _is(FlowKind.nested);
  static final _isPreload = _is(FlowKind.preload);
  static final _pressure = _is(FlowKind.pressure);

  /// The site on screen: the one a return home leaves, and the one a nested
  /// screen covers.
  static final _onScreen = Expr.op<WebViewModel, ActivationFlow>(
    HandPaired.onScreen,
    tla: 'current',
    run: (c) => ActivationFlow.page.from(c).shown!,
    reads: const Reads(vars: {ModelVar.current}),
  );

  /// The target's saved back stack queued for its active tab, and the
  /// frame after a commit building its webview (TAB-003).
  static final _queuedWrite = TabVars.queued<ActivationFlow>().becomes(
    TabVars.staged<ActivationFlow>()
        .call([_site.value, _navAs.value, _navTab.value]),
  );

  /// What the nav read names when it is issued: the site the target's slot
  /// runs as, and the tab it is on. A home landing can move the tab before
  /// the reply, and the stack read is that tab's.
  static const _navAs = Field<WebViewModel, ActivationFlow>(FlowField.navAs);
  static const _navTab = Field<TabId, ActivationFlow>(FlowField.navTab);
  static final _readsAs = [
    _navAs.becomes(TabVars.slotHost<ActivationFlow>(_site.value)),
    _navTab.becomes(TabVars.active<ActivationFlow>().at(_site.value)),
  ];
  static final _queued = Act.of([_queuedWrite], then: _queueNav);

  /// The code's half of [_queuedWrite]: the back stack the nav read,
  /// queued for the next build of the target's active tab.
  static void _queueNav(CommitView<ActivationFlow> c) {
    final target = _site.of(c);
    if (ActivationFlow.state.from(c).navBytes case final bytes?) {
      target.tabBinding.queue(bytes, tab: _navTab.of(c), commit: c.commit);
      LogTag.webViewState.debug(
        'Queued ${bytes.length} restore bytes for "${target.name}" '
        '(siteId: ${target.siteId})',
        sensitive: true,
      );
    }
  }
  /// The frame after the resume builds the target's webview, if it is
  /// still loaded.
  static final _framed = TabVars.framed(_site.value, loaded: _loaded.value);

  /// The frame after a preload's commit builds the site's webview: the
  /// commit loads it, so the frame sees it loaded.
  static final _preloadFramed = TabVars.framed(
    _site.value,
    loaded: _loaded.value.union(_site.value.asSet),
  );
  static final _containers = Constant<bool, ActivationFlow>(
    ModelConst.containers,
    read: (w) => w.reach.sites.useContainers,
  ).value;

  /// The model's variables as the activation reads and writes them: the
  /// version its inputs count, the loaded sites, in use order, the site on
  /// screen and the marker of the activation in flight.
  static final _version = Mutable<int, ActivationFlow>.over(
    ModelVar.version,
    of: (w) => w.reach.sites.vars.version,
  );
  static final _marker =
      Mutable<({WebViewModel target, int version})?, ActivationFlow>.over(
        ModelVar.marker,
        of: (w) => w.reach.sites.vars.marker,
      );

  static final _markerVersion = _marker.value.part('v', get: (m) => m?.version);
  static final _noMarker =
      Expr.constant<({WebViewModel target, int version})?, ActivationFlow>(
        null,
        tla: 'NoMarker',
      );

  /// The site an input names, `s` in the model: the one tapped or preloaded,
  /// from the sites on the list (`Listed`).
  static final _eachSite = Pick<WebViewModel, ActivationFlow>(
    Expr.op(
      HandPaired.listedSites,
      tla: 'Listed',
      run: (c) => [ActivationFlow.state.from(c).target!], reads: const Reads(base: {BaseOp.listed}),
    ),
  );
  static final _chosen = _eachSite.it;

  /// The site a home reset unloads, from the listed sites a world lets it
  /// name (`Resettable`).
  static final _eachResettable = Pick<WebViewModel, ActivationFlow>(
    Expr.op(
      HandPaired.resettableSites,
      tla: r'Listed \cap Resettable',
      run: (c) => [ActivationFlow.state.from(c).target!],
      reads: const Reads(base: {BaseOp.listed}),
      needs: const {(of: ModelConst.resettable, set: true)},
    ),
  );

  /// The site a switch spawns the load of: `k`, beside the switch's own
  /// pick of what it stops showing.
  static final _eachKept = Pick<WebViewModel, ActivationFlow>(
    Expr.op(
      HandPaired.keptSites,
      tla: 'Listed',
      run: (c) => [ActivationFlow.state.from(c).target!],
      reads: const Reads(base: {BaseOp.listed}),
    ),
    name: 'k',
  );
  static final _bump = Act.of([_version.becomes(_version.value.plus(1))]);
  static Act<ActivationFlow> _markerFor(Expr<WebViewModel, ActivationFlow> s) =>
      Act.of([
        _marker.becomes(
          record(
            {'t': s, 'v': _version.value.plus(1)},
            run: (c) => (target: s.run(c), version: _version.value.run(c) + 1),
          ),
        ),
      ]);
  static final _markerSet = _markerFor(_chosen);
  static final _newestIs = modelOnly<ActivationFlow>(
    "newest' = f",
    writes: {ModelVar.newest},
    reads: Reads.none,
  );
  static final _newestNone = modelOnly<ActivationFlow>(
    "newest' = 0",
    writes: {ModelVar.newest},
    reads: Reads.none,
  );

  /// Another site by any way leaves the Tabs sheet's way back behind
  /// (TAB-019); a jump the sheet makes puts its own back once it lands.
  static final _forgetReturns = Note<ActivationFlow>(
    (c) {
      final p = ActivationFlow.page.from(c);
      if (!identical(ActivationFlow.state.from(c).target, p.shown)) p.forgetTabReturns();
    },
  );

  /// A target with a webview keeps its back stack; one about to be built
  /// first reads the stack saved for it, unless its tab keeps none (a
  /// kiosk's): the model's `NoNavState`, which holds no site there.
  static final _noNavState = Members<WebViewModel, ActivationFlow>(
    ModelConst.noNavState,
    test: (_, {required member}) => !member.activeTabPersistsNavState,
  );

  static Expr<bool, ActivationFlow> _inFlight(FlowKind k) =>
      Expr.inFlight(
        k,
        run: (c) => ActivationFlow.page.from(c).kindsInFlight.contains(k),
      );

  /// A memory-pressure event while one is still applying its plan is
  /// dropped.
  static final _pressureRunning = _inFlight(FlowKind.pressure);

  /// An activation is in flight: a witness's term.
  static final midActivation = Def<bool, ActivationFlow>(
    ModelDef.midActivation,
    body: _inFlight(FlowKind.tap),
  );

  static const _s = Bound<WebViewModel, ActivationFlow>('s');
  static const _u = Bound<WebViewModel, ActivationFlow>('u');
  static Expr<bool, ActivationFlow> _evictable(
    Expr<WebViewModel, ActivationFlow> s,
  ) => ModelDef.evictable.over(
    [s],
    run: (c) => ActivationFlow.page.from(c).isEvictable(s.run(c)),
  );
  static Expr<bool, ActivationFlow> _at(
    Expr<WebViewModel, ActivationFlow> s, {
    required SiteLifecycleState tier,
    required String tla,
  }) => _tier.at(s).eq(Expr.constant(tier, tla: tla));

  /// What a pressure plan picks from: the evictable residents, else the
  /// evictable cleared sites; among them the one retention priority takes
  /// first (SiteRuntime.firstToEvict).
  static final pressureResident = Def<List<WebViewModel>, ActivationFlow>(
    ModelDef.pressureResident,
    body: _loaded.value.where(
      _s,
      holds:
          _evictable(_s.it) &
          _at(_s.it, tier: SiteLifecycleState.resident, tla: '"resident"'),
    ),
  );
  static final pressureCleared = Def<List<WebViewModel>, ActivationFlow>(
    ModelDef.pressureCleared,
    body: _loaded.value.where(
      _s,
      holds:
          _evictable(_s.it) &
          _at(_s.it, tier: SiteLifecycleState.cacheCleared, tla: '"cleared"'),
    ),
  );
  static WebViewModel _firstToEvict(
    StepView<ActivationFlow> c, {
    required List<WebViewModel> among,
  }) => ActivationFlow.page.from(c).firstToEvict(among);
  static final _eachResident = Pick(
    pressureResident.value,
    first: _firstToEvict,
  );
  static final _eachCleared = Pick(pressureCleared.value, first: _firstToEvict);

  /// A preload's conditions: in the launch, with no activation or other
  /// preload in flight (the preloads' own queue), a site not loaded whose
  /// base domain no loaded site holds on the shared jar. The launch is the
  /// proof the input carries, which only the restore makes (ColdStart).
  static final _coldStart = Expr.ofConstant<bool, ActivationFlow>(
    ModelConst.coldStart,
    run: (c) => ActivationFlow.state.from(c).launch != null,
  );
  static final _noPreloadInFlight = ~_inFlight(FlowKind.preload);

  /// What a load of [s] off screen needs, whatever starts it: no other
  /// preload in flight, [s] not loaded, its base domain free on the shared
  /// jar, and its route free.
  static Expr<bool, ActivationFlow> _keepable(
    Expr<WebViewModel, ActivationFlow> s,
  ) =>
      _noPreloadInFlight &
      ~_loaded.value.has(s) &
      (_containers | _baseFree(s)) &
      routeFree.call([_runsAs(s)]);

  /// The loaded sites [s] cannot share the jar with (SiteUnloadEngine's
  /// `Conflicts`).
  static Expr<List<WebViewModel>, ActivationFlow> _conflicts(
    Expr<WebViewModel, ActivationFlow> s,
  ) => ModelDef.conflicts.over(
    [s],
    run: (c) => ActivationFlow.page.from(c).conflicts(s.run(c)),
  );
  static Expr<bool, ActivationFlow> _baseFree(
    Expr<WebViewModel, ActivationFlow> s,
  ) => _conflicts(s).isEmpty;
  static final _loaded = Mutable<Iterable<WebViewModel>, ActivationFlow>.over(
    ModelVar.loaded,
    of: (w) => w.reach.sites.vars.loaded,
  );
  static final _current = Mutable<WebViewModel?, ActivationFlow>.over(
    ModelVar.current,
    of: (w) => w.reach.sites.vars.current,
  );
  static final _noSite = Expr.constant<WebViewModel?, ActivationFlow>(
    null,
    tla: '0',
  );

  /// The sites whose containers the model follows, which a close or a
  /// delete takes away (`Boxed`): every site binds one in the code; the
  /// webviews mounted and the containers on disk are the platform's,
  /// written only by its calls.
  static final _boxed = Expr.ofConstant<Iterable<WebViewModel>, ActivationFlow>(
    ModelConst.boxed,
    run: (c) => ActivationFlow.page.from(c).models,
  );
  static final _boxes = Mutable<Iterable<WebViewModel>, ActivationFlow>.remote(
    ModelVar.boxes,
  );
  static final _views = Mutable<Iterable<WebViewModel>, ActivationFlow>.remote(
    ModelVar.views,
  );
  static final _siteGone = Expr.op<bool, ActivationFlow>(
    HandPaired.activationSiteGone,
    tla: '${_site.value.tla} \\in gone',
    run: (c) => !ActivationFlow.page.from(c).models.contains(_site.of(c)),
    reads: _site.value.reads + const Reads(vars: {ModelVar.gone}),
  );
  static final _tier = tierOf<ActivationFlow>();

  /// The shared jar never holds two loaded sites of one base domain
  /// (ISO-001, the model's Inv_OneSitePerBase), asserted where a site is
  /// loaded.
  static final _oneSitePerBase = _loaded.value.forAll(
    _u,
    holds: _conflicts(_u.it).isEmpty,
  );

  /// A webview running as the site [a] would repoint no running webview's
  /// proxy or Tor exit (PROXY-008): what a load that runs no plan needs. A
  /// slot asks for the site it runs as, a page for its own.
  static final routeFree = () {
    const a = Bound<WebViewModel, ActivationFlow>('a');
    return Def<bool, ActivationFlow>(
      ModelDef.routeFree,
      params: const [a],
      body: _contendersOf(a.it).isEmpty & _dissentersOf(a.it).isEmpty,
    );
  }();

  /// Running webviews that share a proxy scope run one route, and running
  /// Tor webviews one exit (PROXY-008, the model's Inv_OneRoute), asserted
  /// where a site is loaded or a nested screen goes up: each loaded slot as
  /// the site it runs as, each page as its own. Stated from the rules, not
  /// from [routeFree], so a mistake in the guard is one this catches.
  static final _oneRoute =
      _loaded.value.forAll(_u, holds: _alone(_runsAs(_u.it))) &
      _pages.forAll(_u, holds: _alone(_u.it));
  static Expr<bool, ActivationFlow> _alone(Expr<WebViewModel, ActivationFlow> a) =>
      _contendersOf(a).isEmpty & _dissentersOf(a).isEmpty;

  /// The switch leaves a site: the one on screen is another loaded site
  /// (nothing to do when the user tapped the site they are on).
  static final _outgoing =
      _current.value.neq(_noSite) &
      _current.value.neq(_site.value) &
      _loaded.value.has(_current.value);

  static WebViewModel? _outgoingSite(StepView<ActivationFlow> c) =>
      _outgoing.run(c) ? _current.value.run(c) : null;

  /// The slot's proxy route is shared and must move before the target
  /// loads (LIR-024): the model's `Routed`, which holds no site there.
  static final _routed = Members<WebViewModel, ActivationFlow>(
    ModelConst.routed,
    test: (w, {required member}) =>
        switch (w.reach.residency.proxyTopology) {
          RoutedProxy(:final sharesDefaultSession) => sharesDefaultSession(
            member,
          ),
          PerSessionProxy() || ProcessGlobalProxy() => false,
        },
  ).has(_site.value);

  /// The site whose nested screen is up (`nested`), 0 for none.
  static final _nested = Mutable<WebViewModel?, ActivationFlow>.over(
    ModelVar.nested,
    of: (w) => w.reach.sites.vars.nested,
  );
  static final _nestedUp = Act.of([_nested.becomes(_site.value)]);
  static final _nestedDown = Act.of([_nested.becomes(_noSite)]);

  /// The pages whose traffic runs, each as its own site: a nested screen
  /// and a wake's checks (the runtime's `Pages`).
  static final _pages = ModelDef.pages.named<Iterable<WebViewModel>, ActivationFlow>(
    run: (c) => ActivationFlow.page.from(c).pages,
  );

  /// The sites a link may open nested: any in the code, as many as a
  /// configuration of the model follows (`Linked`).
  static final _linked = Members<WebViewModel, ActivationFlow>(
    ModelConst.linked,
    test: (_, {required member}) => true,
  );
  static final _noNestedOpen = ~_inFlight(FlowKind.nested);

  /// The sites that share a contended proxy scope (`Contending`): every one
  /// under a process-global proxy, the router's default session, none per
  /// session. A nested screen as one of them moves the rule they share.
  static final _contending = Members<WebViewModel, ActivationFlow>(
    ModelConst.contending,
    test: (w, {required member}) =>
        w.reach.residency.proxyTopology.contends(member),
  );

  /// The proxy did not apply; the model's environment always applies it.
  static final _refused = Expr.ofConstant<bool, ActivationFlow>(
    ModelConst.proxyRefused,
    run: (c) => ActivationFlow.state.from(c).refused,
  );

  /// The sites a webspace switch stops showing: any of `Away`, the list's.
  static final _eachAway = Pick<List<WebViewModel>, ActivationFlow>(
    Expr.ofConstant(
      ModelConst.away,
      run: (c) => [ActivationFlow.state.from(c).leaving!.toList()],
    ),
  );
  static const _away = Field<List<WebViewModel>, ActivationFlow>(FlowField.away);
  static const _behind = Field<WebViewModel?, ActivationFlow>(FlowField.behind);

  /// The target of the activation in flight while no input has superseded
  /// it, the model's `LiveTarget`.
  static final _liveTarget = Expr.op<WebViewModel?, ActivationFlow>(
    HandPaired.liveTarget,
    tla: 'LiveTarget',
    run: (c) => ActivationFlow.page.from(c).liveTarget,
    reads: const Reads(base: {BaseOp.liveTarget}),
  );
  static final _behindSite = _behind.value.unwrapped;
  static final _online = Expr.ofConstant<bool, ActivationFlow>(
    ModelConst.online,
    run: (c) => ActivationFlow.state.from(c).online,
  );

  /// What a switch unloads on the shared jar: the loaded sites it stops
  /// showing that may go; the code's plan is asserted to be these.
  static final _leftBehind = () {
    final rule = Expr.choose(
      when: _containers,
      then: Expr.none<WebViewModel, ActivationFlow>(),
      otherwise: _loaded.value.where(
        _u,
        holds:
            _away.value.has(_u.it) &
            _evictable(_u.it) &
            _behind.value.neq(_u.it),
      ),
    );
    return Expr.checked(
      rule: rule,
      run: (c) => [for (final u in _planOf(c).unloads) u.site],
      key: (s) => s,
      why: 'the switch unloads what its printed rule names',
    );
  }();

  /// A webspace chosen on the list (WEBSPACE-013): it supersedes an
  /// activation in flight, as going home does, keeps the site that one was
  /// opening loading behind the list, and holds what it stops showing. Offline every webview stays, so its cached page can still be
  /// read; online the plan is what the switch leaves behind.
  static final _spaceFlow = FlowInput<ActivationFlow, ActivationPlace>(
    ActivationStep.spaceSwitch,
    at: ActivationPlace.space,
    enabled: _current.value.eq(_noSite) & _nested.value.eq(_noSite),
    pick: _eachAway,
    decide: spaceInputOf(supersedes: true),
  );
  static final _spaceSteps = _spaceFlow.steps;

  static final _spaceOnline = Await<ActivationFlow, ActivationPlace>(
    ActivationStep.spaceOnlineReply,
    at: ActivationPlace.sOnline,
    holds: null,
    call: Call.on(
      ActivationFlow.page,
      run: (c) async => ActivationFlow.state.from(c).online = await c.api.isOnline(),
      writes: const [],
    ),
    decide: When(
      _stale,
      then: Ends(StepOutcome.stale, next: GoTo(to(ActivationPlace.done))),
      otherwise: When(
        ~_online,
        then: Ends(
          StepOutcome.skip,
          does: [
            Note((_) => LogTag.webspaceSwitch.debug('Offline: webviews kept')),
            modelOnly(
              'seen\' = seen \\cup {"offline"}',
              writes: {ModelVar.seen},
              reads: const Reads(vars: {ModelVar.seen}),
            ),
            _keepBehind,
          ],
          next: GoTo(to(ActivationPlace.done)),
        ),
        otherwise: Ends(
          StepOutcome.go,
          does: [
            _victims.becomes(_leftBehind),
            _clears.becomes(Expr.none()),
            _picked.becomes(_leftBehind),
            _keepBehind,
          ],
          next: GoTo(_afterUnloads(victims: _leftBehind, clears: Expr.none())),
        ),
      ),
    ),
  );

  /// The site whose opening the switch superseded goes on loading behind
  /// the list, once the switch knows whether the device is online and no
  /// input has superseded the switch in turn.
  static final _keepBehind = Spawn<ActivationFlow>(
    ActivationStep.spaceKeep,
    site: _behind.value,
    when: _behind.value.neq(_noSite) & _keepable(_behindSite),
    start: (c) => ActivationFlow.page.from(c).keepLoading(_behind.of(c)!),
  );

  /// The switch's input: what it stops showing, and the version it bumps
  /// past an activation in flight ([supersedes]).
  static Ends<ActivationFlow, ActivationPlace> spaceInputOf({
    required bool supersedes,
  }) => Ends(
    StepOutcome.none,
    does: [
      kind.becomes(Expr.constant(FlowKind.space)),
      _away.becomes(_eachAway.it),
      if (supersedes) ...[
        _behind.becomes(_liveTarget),
        _v.becomes(_version.value.plus(1)),
        _bump,
        _newestNone,
      ] else ...[_behind.becomes(_noSite), _v.becomes(_version.value)],
    ],
    next: _spaceOnline,
  );

  /// The running sites a nested screen as the flow's site would repoint:
  /// its plan's unloads (`NestedOpening`), the proxy's contenders and the
  /// Tor exit's dissenters.
  static ResidencyPlan _nestedPlan(StepView<ActivationFlow> c) {
    final page = ActivationFlow.page.from(c);
    return page.residencyPlan(
      NestedOpening(page.models.indexOf(_site.of(c))),
    );
  }
  static final _screenVictims = Expr.checked(
    rule: _contendersOf(_site.value).union(_dissentersOf(_site.value)),
    run: (c) => {for (final u in _nestedPlan(c).unloads) u.site},
    key: (s) => s,
    why: 'a nested open unloads what its printed rules name',
  );

  /// A round of a nested open's unloads: the plan the unload loop runs, and
  /// whether it takes the site the link came from.
  static final _unloadForScreen = <Effect<ActivationFlow>>[
    _victims.becomes(_screenVictims),
    _clears.becomes(Expr.none()),
    _picked.becomes(Expr.none()),
    Note<ActivationFlow>((c) => ActivationFlow.state.from(c).plan = _nestedPlan(c)),
  ];

  /// The screen is gone, and what it ran on is released.
  static final _screenGone = Note<ActivationFlow>(
    (c) => ActivationFlow.state.from(c).opening!.screen.closed(_site.of(c)),
  );

  /// The running sites a webview running as [a] would repoint the proxy of
  /// (PROXY-008), as the unload engine's `ProxyContenders` names them: a
  /// slot's activation asks for the site it runs as (LIR-024), a nested
  /// screen for its own site whatever its slot shows (`NestedOpening`).
  static Expr<List<WebViewModel>, ActivationFlow> _contendersOf(
    Expr<WebViewModel, ActivationFlow> a,
  ) => ModelDef.proxyContenders.over(
    [a],
    run: (c) => ActivationFlow.page.from(c).proxyContenders(runsAs: a.run(c)),
  );

  static Expr<WebViewModel, ActivationFlow> _runsAs(
    Expr<WebViewModel, ActivationFlow> s,
  ) => TabVars.runsAs<ActivationFlow>().call([s]);

  /// The running sites whose Tor exit a webview running as [a] would
  /// repoint, when a Tor runtime exists (`TorDissenters`).
  static Expr<List<WebViewModel>, ActivationFlow> _dissentersOf(
    Expr<WebViewModel, ActivationFlow> a,
  ) => Expr.choose(
    when: _torRuntime,
    then: ModelDef.torDissenters.over(
      [a],
      run: (c) => ActivationFlow.page.from(c).torDissenters(runsAs: a.run(c)),
    ),
    otherwise: Expr.none(),
  );
  static final _torRuntime = Constant<bool, ActivationFlow>(
    ModelConst.torRuntime,
    read: (w) => w.reach.residency.torAvailable,
  ).value;

  /// The loaded sites the residency's rules name for [s], which a plan can
  /// unload: the jar's conflicts, the proxy's contenders and the Tor exit's
  /// dissenters. A page they name is no site to unload, and no activation
  /// starts beside one (`Reopens`).
  static final ruled = () {
    const s = Bound<WebViewModel, ActivationFlow>('s');
    const v = Bound<WebViewModel, ActivationFlow>('v');
    return Def<List<WebViewModel>, ActivationFlow>(
      ModelDef.ruled,
      params: const [s],
      body: _conflicts(s.it)
          .union(_contendersOf(_runsAs(s.it)))
          .union(_dissentersOf(_runsAs(s.it)))
          .where(v, holds: _loaded.value.has(v.it)),
    );
  }();
  static Expr<List<WebViewModel>, ActivationFlow> _ruled(
    Expr<WebViewModel, ActivationFlow> s,
  ) => ruled.call([s]);

  /// The loaded sites the rules leave for [s], which the loaded-site cap
  /// picks among.
  static final kept = () {
    const s = Bound<WebViewModel, ActivationFlow>('s');
    return Def<List<WebViewModel>, ActivationFlow>(
      ModelDef.kept,
      params: const [s],
      body: _loaded.value.less(ruled.call([s.it])),
    );
  }();

  /// The target's kept sites (the target only counts toward the cap).
  static final _kept = kept.call([_site.value]);

  /// The loaded-site cap's picks (`MaxLoaded`): as many as the kept sites
  /// and the target exceed it, among the evictable kept sites but the
  /// target, as many as there are. The model takes any; the code the
  /// oldest by retention priority, asserted to be one of them.
  static final _capCandidates = _kept
      .without(_site.value)
      .where(_u, holds: _evictable(_u.it));
  static final _capPick = Pick<List<WebViewModel>, ActivationFlow>(
    _capCandidates.choices(
      size: _kept
          .union(_site.value.asSet)
          .size
          .over(_maxLoaded)
          .atMost(_capCandidates.size),
      taken: (c) => [
        for (final u in _planOf(c).unloads)
          if (u.reason == UnloadReason.loadedSiteCap) u.site,
      ],
    ),
    name: 'cap',
  );

  /// The proactive cache clear's picks (`MaxResident`): as many as the
  /// resident sites the plan leaves exceed it, among the evictable ones.
  static final _residentsLeft = _kept
      .less(_capPick.it)
      .where(
        _u,
        holds: _tier
            .at(_u.it)
            .eq(Expr.constant(SiteLifecycleState.resident, tla: '"resident"')),
      );
  static final _clearCandidates = _residentsLeft.where(
    _u,
    holds: _evictable(_u.it),
  );
  static final _clearPick = Pick<List<WebViewModel>, ActivationFlow>(
    _clearCandidates.choices(
      size: _residentsLeft.size
          .over(_maxResident)
          .atMost(_clearCandidates.size),
      taken: (c) => _planOf(c).cacheClears,
    ),
    name: 'clr',
  );
  static final _maxLoaded = Constant<int, ActivationFlow>(
    ModelConst.maxLoaded,
    read: (w) => w.reach.residency.caps.loaded,
  ).value;
  static final _maxResident = Constant<int, ActivationFlow>(
    ModelConst.maxResident,
    read: (w) => w.reach.residency.caps.resident,
  ).value;

  /// The sites a tap's residency unloads: what the rules name and the
  /// cap's picks; the code's plan is asserted to be exactly these.
  static final _planVictims = Expr.checked(
    rule: _ruled(_site.value).union(_capPick.it),
    run: (c) => [for (final u in _planOf(c).unloads) u.site],
    key: (s) => s,
    why: 'the plan unloads what its printed rules and picks name',
  );
  static final _planClears = Expr.chosen(
    among: _clearPick.it,
    run: (c) => _planOf(c).cacheClears,
  );

  /// The plan's priority picks: the loaded-site cap's.
  static final _planPicked = Expr.chosen(
    among: _capPick.it,
    run: (c) => SiteUnloadEngine.pickedOf(_planOf(c)),
  );

  /// The residency plan for the target, made at the plan step the first
  /// time it is read there (its next place reads it before its effects do)
  /// and kept for the unload flow; a pressure plan is its own step's.
  static ResidencyPlan _planOf(StepView<ActivationFlow> c) {
    final page = ActivationFlow.page.from(c);
    final models = page.models;
    return ActivationFlow.state.from(c).plan ??= page.residencyPlan(switch (kind.of(c)) {
        FlowKind.tap || FlowKind.preload || FlowKind.home => Activating(
          models.indexOf(_site.of(c)),
        ),
        FlowKind.pressure => throw StateError('made by the pressure plan step'),
        FlowKind.unload => throw StateError('made by the unload\'s caller'),
        FlowKind.nested => NestedOpening(models.indexOf(_site.of(c))),
        FlowKind.space => WebspaceSwitched(
          leaving: {
            for (final m in _away.of(c))
              if (models.contains(m) && !identical(m, _behind.of(c)))
                models.indexOf(m),
          },
        ),
        FlowKind.tab => throw StateError('a tab flow plans no residency'),
        FlowKind.wake => throw StateError('a wake plans no residency'),
        FlowKind.dns => throw StateError('a DNS download plans no residency'),
        FlowKind.close => throw StateError('an archive close plans no residency'),
        FlowKind.delete => throw StateError('a delete plans no residency'),
      });
  }

  /// Where a spent plan goes: the unload engine's own rule.
  static Expr<ActivationPlace, ActivationFlow> _afterUnloads({
    required Expr<List<WebViewModel>, ActivationFlow> victims,
    required Expr<List<WebViewModel>, ActivationFlow> clears,
  }) => SiteUnloadEngine.afterUnloads(
    victims: victims,
    clears: clears,
    next: ActivationPlace.next,
    nextClear: ActivationPlace.nextClear,
    applied: ActivationPlace.applied,
  );

  static final _tierResident = Act.of([
    _tier.except(_site.value, to: Expr.constant(SiteLifecycleState.resident)),
  ]);
  static final _loadedAdd = Act.of(
    [_loaded.becomes(_loaded.value.union(_site.value.asSet))],
    then: (c) {
      assert(
        _oneSitePerBase.run(c),
        'the shared jar holds two loaded sites of one base domain (ISO-001)',
      );
      assert(
        _oneRoute.run(c),
        'two running sites in one proxy scope run different routes (PROXY-008)',
      );
      ActivationFlow.state.from(c).committed = true;
    },
  );
  static final _showSite = Act.of([_current.becomes(_site.value)]);
  static final _preloaded = modelOnly<ActivationFlow>(
    'seen\' = seen \\cup {"preloaded"}',
    writes: {ModelVar.seen},
    reads: const Reads(vars: {ModelVar.seen}),
  );
  static final _enqueue = modelOnly<ActivationFlow>(
    'Enqueue(f)',
    writes: {ModelVar.queue, ModelVar.seen},
    reads: const Reads(base: {BaseOp.enqueue}),
  );

  /// The marker goes only with its own activation: a newer one overwrote
  /// it, the same target on a double tap included (CONT-003).
  static final _markerOff = Act.of([
    _marker.becomes(
      Expr.choose(
        when: _is(FlowKind.tap) & _markerVersion.eq(_v.value),
        then: _noMarker,
        otherwise: _marker.value,
      ),
    ),
  ]);
  static final _homeOff = Act.of([
    _current.becomes(_noSite),
  ], then: (c) => ActivationFlow.page.from(c).leftForHome());
  static final _newestOff = modelOnly<ActivationFlow>(
    'newest\' = IF newest = f THEN 0 ELSE newest',
    writes: {ModelVar.newest},
    reads: const Reads(vars: {ModelVar.newest}),
  );
  static final _bailedAfterUnload = modelOnly<ActivationFlow>(
    'seen\' = seen \\cup (IF fl[f].unloaded /\\ fl[f].v # version '
    'THEN {"bailAfterUnload"} ELSE {})',
    writes: {ModelVar.seen},
    reads: const Reads(vars: {ModelVar.seen, ModelVar.version}),
  );

  /// A superseded switch's finally, after its residency unloaded the site
  /// on screen: a row move bumps the version without choosing a site, so
  /// nothing else would leave that site with no webview behind it (LAZY-007,
  /// BUG-029).
  static final _screenEmpty =
      _shows &
      _current.value.neq(_noSite) &
      ~_loaded.value.has(_current.value);

  /// On to the target's cookies: its container, or its turn on the jar.
  static List<Branch<ActivationFlow, ActivationPlace>> _toCookies(
    StepOutcome go, {
    List<Effect<ActivationFlow>> then = const [],
  }) => [
    Branch(go, when: _containers, then: then, next: to(ActivationPlace.cont)),
  ];
  static Otherwise<ActivationFlow, ActivationPlace> _toJar(
    StepOutcome go, {
    List<Effect<ActivationFlow>> then = const [],
  }) =>
      Otherwise(go, then: [...then, _enqueue], next: to(ActivationPlace.rTurn));

  /// The tor exit pin follows the loaded sites once the disagreeing siblings
  /// are gone: SETCONF takes effect for the whole runtime the moment it
  /// lands (TOR-014). Not awaited: a target that uses Tor is held behind the
  /// interstitial until the pin lands.
  static final _torPin = Note<ActivationFlow>(
    (c) => ActivationFlow.page.from(c).syncTorExitPin(_site.of(c)),
  );

  static Future<ActivationPlace> _inUnload(
    StepView<ActivationFlow> c, {
    required ActivationPlace from,
  }) async {
    final left = await SiteUnloadEngine.unloadFlow.run(
      StepContext.sharing(
        c,
        world: UnloadFlow(
          host: ActivationFlow.nest.from(c).residency,
          plan: _planOf(c),
          isStale: () => stale.value.run(c),
        ),
      ),
      from: UnloadPlace.values.byName(from.name),
    );
    return ActivationPlace.values.byName(left.name);
  }

  static Future<ActivationPlace> _inRestore(
    StepView<ActivationFlow> c, {
    required ActivationPlace from,
  }) async {
    final nest = ActivationFlow.nest.from(c);
    final left = switch (nest.isolation) {
      SharedJar(:final jar) => await jar.restoreInTurn(
        StepContext.sharing(
          c,
          world: RestoreWorld(engine: jar, vars: nest.vars),
        ),
        from: RestorePlace.values.byName(from.name),
      ),
      Containers() => throw StateError(
        'a flow at ${from.name} under containers: the jar\'s places are '
        'reached only by the jar path',
      ),
    };
    return ActivationPlace.values.byName(left.name);
  }

  /// An activation, a preload and a return home, between their awaits, with
  /// the unload engine's table nested at its places and the jar's restore
  /// at the jar's.
  /// Going home captures the site left, in the capture's steps.
  static final _homeCapture =
      captureSteps<WebViewModel, ActivationFlow, ActivationPlace>(
        names: (
          read: ActivationStep.homeCapture,
          save: ActivationStep.homeCaptureSave,
          unsave: ActivationStep.homeCaptureUnsave,
        ),
        places: (
          save: ActivationPlace.hCapSave,
          unsave: ActivationPlace.hCapUnsave,
          after: to(ActivationPlace.hQuiesce),
        ),
        of: (
          site: _site.value,
          built: (s) => s.tabBinding.built,
          hosts: (s) => s.tabHosts,
          begin: (c) => ActivationFlow.page.from(c).beginNavCapture(_site.of(c)),
          marks: null,
          keeps: null,
        ),
      );

  static final activationFlow = StepTable<ActivationFlow, ActivationPlace>(
    ActivationPlace.values,
    ending: {ActivationPlace.done},
    awaited: {ActivationPlace.applied, ActivationPlace.exit},
    vars: [_loaded, _current, _nested],
    at: (place) => switch (place) {
      // activate(site): the bump and the marker before any await; a target
      // not loaded first reads its saved navigation state.
      ActivationPlace.tap => Step.input(
        ActivationStep.tap,
        pick: _eachSite,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            _forgetReturns,
            kind.becomes(Expr.constant(FlowKind.tap)),
            _site.becomes(_chosen),
            _v.becomes(_version.value.plus(1)),
            _markerSet,
            _bump,
            _newestIs,
          ],
          next: Expr.choose(
            when: _loaded.value.has(_chosen) | _noNavState.has(_chosen),
            then: to(ActivationPlace.plan),
            otherwise: to(ActivationPlace.nav),
          ),
        ),
      ),
      // activate(null): home is committed before any await (NAV-010); a
      // site left loaded has its state captured.
      ActivationPlace.goHome => Step.input(
        ActivationStep.goHome,
        branches: [
          Branch(
            StepOutcome.none,
            when:
                _current.value.neq(_noSite) & _loaded.value.has(_current.value),
            then: [
              _forgetReturns,
              _site.becomes(_onScreen),
              kind.becomes(Expr.constant(FlowKind.home)),
              _v.becomes(_version.value.plus(1)),
              _bump,
              _homeOff,
              _newestNone,
            ],
            next: to(ActivationPlace.hCap),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.none,
          then: [_forgetReturns, _bump, _homeOff, _newestNone],
          next: to(ActivationPlace.done),
        ),
      ),
      // memoryPressure: dropped while one runs; else it plans.
      ActivationPlace.pressure => Step.input(
        ActivationStep.pressure,
        branches: [
          Branch(
            StepOutcome.none,
            when: _pressureRunning,
            then: [],
            next: to(ActivationPlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.none,
          then: [kind.becomes(Expr.constant(FlowKind.pressure))],
          next: to(ActivationPlace.pplan),
        ),
      ),
      // The plan: a resident evictable site drops its cache, else a cleared
      // one is unloaded; a loaded site at "saved" is never picked. The
      // active site and an in-flight activation's target are never picked
      // (PAUSE-006).
      ActivationPlace.pplan => Step(
        ActivationStep.pressurePlan,
        holds: null,
        branches: [
          Branch(
            StepOutcome.empty,
            when: pressureResident.value.isEmpty & pressureCleared.value.isEmpty,
            then: [],
            next: to(ActivationPlace.done),
          ),
          Branch(
            StepOutcome.clear,
            when: ~pressureResident.value.isEmpty,
            pick: _eachResident,
            site: _eachResident.it,
            then: [
              _clears.becomes(_eachResident.it.asSet),
              _victims.becomes(Expr.none()),
              _picked.becomes(Expr.none()),
              Note(
                (c) => ActivationFlow.state.from(c).plan = ResidencyPlan(
                  cacheClears: [_eachResident.it.run(c)],
                ),
              ),
            ],
            next: to(ActivationPlace.nextClear),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.unload,
          pick: _eachCleared,
          site: _eachCleared.it,
          then: [
            _victims.becomes(_eachCleared.it.asSet),
            _clears.becomes(Expr.none()),
            _picked.becomes(_eachCleared.it.asSet),
            Note(
              (c) => ActivationFlow.state.from(c).plan = ResidencyPlan(
                unloads: [
                  (
                    site: _eachCleared.it.run(c),
                    reason: UnloadReason.memoryPressure,
                  ),
                ],
              ),
            ),
          ],
          next: to(ActivationPlace.next),
        ),
      ),
      // preload(siteId) at launch: a site not loaded, whose base domain no
      // loaded site holds on the shared jar and whose proxy route and Tor
      // exit no loaded site in its scope differs from (a background load
      // runs no residency plan, so it may not repoint a proxy, PROXY-008),
      // with no activation or other preload in flight. It bumps no version,
      // so it supersedes nothing; any input after it supersedes it.
      ActivationPlace.preload => Step.input(
        ActivationStep.preload,
        enabled: _coldStart & _marker.value.eq(_noMarker) & _keepable(_chosen),
        pick: _eachSite,
        site: _chosen,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            kind.becomes(Expr.constant(FlowKind.preload)),
            _site.becomes(_chosen),
            _v.becomes(_version.value),
          ],
          next: to(ActivationPlace.pNav),
        ),
      ),
      // unload(site) at a home reset, of a site off screen: a plan of that
      // site alone, which it picks, so the unload backs off if the site has
      // come on screen or become a tap's target by its dispose (BUG-033). It
      // bumps no version, so it supersedes nothing.
      ActivationPlace.unload => Step.input(
        ActivationStep.unloadSite,
        enabled: _current.value.neq(_eachResettable.it),
        pick: _eachResettable,
        site: _eachResettable.it,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            kind.becomes(Expr.constant(FlowKind.unload)),
            _victims.becomes(_eachResettable.it.asSet),
            _clears.becomes(Expr.none()),
            _picked.becomes(_eachResettable.it.asSet),
          ],
          next: to(ActivationPlace.next),
        ),
      ),
      // The target's saved back stack read, handed to the model so the
      // build's onControllerCreated applies restoreState.
      ActivationPlace.nav => Step(
        ActivationStep.navReply,
        holds: null,
        call: Call.on(
          ActivationFlow.files,
          run: (c) async {
            final target = _site.of(c);
            ActivationFlow.state.from(c).navBytes = await c.api.loadState(
              target.stateKeyForTab(_navTab.of(c)),
            );
          },
          writes: const [],
          reads: _readsAs,
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [_queued],
          next: to(ActivationPlace.plan),
        ),
      ),
      // The target is resident again; the residency plan names the loaded
      // sites it pushes out and the residents that drop their cache. Every
      // rule and its order is SiteUnloadEngine.plan's.
      ActivationPlace.plan => Step(
        ActivationStep.plan,
        holds: null,
        pick: _capPick,
        otherwise: Otherwise(
          StepOutcome.none,
          pick: _clearPick,
          then: [
            _tierResident,
            _victims.becomes(_planVictims),
            _clears.becomes(_planClears),
            _picked.becomes(_planPicked),
          ],
          next: _afterUnloads(victims: _planVictims, clears: _planClears),
        ),
      ),
      ActivationPlace.next ||
      ActivationPlace.uNav ||
      ActivationPlace.uNavSave ||
      ActivationPlace.uNavUnsave ||
      ActivationPlace.uCaptured ||
      ActivationPlace.uTurn ||
      ActivationPlace.uCap ||
      ActivationPlace.uSave ||
      ActivationPlace.uKept ||
      ActivationPlace.afterUnload ||
      ActivationPlace.nextClear ||
      ActivationPlace.cc => const Within(_inUnload),
      // The plan is spent: memory pressure is done; an activation repoints a
      // shared route, pauses the site it leaves, or goes on to its cookies.
      ActivationPlace.applied => Step(
        ActivationStep.applied,
        holds: null,
        branches: [
          Branch(
            StepOutcome.none,
            when: _is(FlowKind.nested),
            then: [],
            next: to(ActivationPlace.nAsk),
          ),
          Branch(
            StepOutcome.none,
            when: _pressure | _is(FlowKind.space) | _is(FlowKind.unload),
            then: [],
            next: to(ActivationPlace.done),
          ),
          Branch(
            StepOutcome.none,
            when: _routed,
            then: [],
            next: to(ActivationPlace.routes),
          ),
          Branch(
            StepOutcome.none,
            when: _outgoing,
            then: [_torPin],
            next: to(ActivationPlace.quiesce),
          ),
          ..._toCookies(StepOutcome.none, then: [_torPin]),
        ],
        otherwise: _toJar(StepOutcome.none, then: [_torPin]),
      ),
      // The shared-profile route is repointed before this site can issue a
      // request: until it lands the relay holds the previous site's upstream.
      ActivationPlace.routes => Step(
        ActivationStep.routesReply,
        holds: null,
        call: Call.on(
          ActivationFlow.page,
          run: (c) => c.api.refreshRoutes(active: _site.of(c)),
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
          Branch(
            StepOutcome.go,
            when: _outgoing,
            then: [_torPin],
            next: to(ActivationPlace.quiesce),
          ),
          ..._toCookies(StepOutcome.go, then: [_torPin]),
        ],
        otherwise: _toJar(StepOutcome.go, then: [_torPin]),
      ),
      // The site left is paused (SiteTeardownEngine); a superseded
      // activation leaves.
      ActivationPlace.quiesce => Step(
        ActivationStep.quiesceReply,
        holds: null,
        call: Call.on(
          ActivationFlow.page,
          run: (c) {
            final outgoing = _outgoingSite(c);
            if (outgoing == null) return Future.value();
            return c.api.pause(outgoing, version: _v.of(c));
          },
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
          ..._toCookies(StepOutcome.go),
        ],
        otherwise: _toJar(StepOutcome.go),
      ),
      // The target's container recorded, which the native side makes when
      // the webview binds by InAppWebViewSettings.containerId.
      // An archive-tier site's opaque container made, for its webview to
      // bind; one made for a site a close took off the list meanwhile is
      // deleted again, as nothing else will (ARCH-014).
      ActivationPlace.cont => Step(
        ActivationStep.contReply,
        holds: null,
        call: Call.on(
          ActivationFlow.boxes,
          run: (c) =>
              c.api?.ensureContainer(_site.of(c).containerKey) ??
              Future.value(),
          writes: [
            _boxes.becomes(
              Expr.choose(
                when: _boxed.has(_site.value),
                then: _boxes.value.union(_site.value.asSet),
                otherwise: _boxes.value,
              ),
            ),
          ],
        ),
        branches: [
          Branch(
            StepOutcome.gone,
            when: _stale & _siteGone,
            then: [],
            next: to(ActivationPlace.contGone),
          ),
          Branch(
            StepOutcome.bail,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.commit,
          then: [],
          next: to(ActivationPlace.html),
        ),
      ),
      ActivationPlace.contGone => Step(
        ActivationStep.contGoneReply,
        holds: null,
        call: Call.on(
          ActivationFlow.boxes,
          run: (c) =>
              c.api?.containerNative.deleteContainer(_site.of(c).containerKey) ??
              Future.value(),
          writes: [
            _boxes.becomes(
              _boxes.value.less(_site.value.asSet.less(_views.value)),
            ),
          ],
        ),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(ActivationPlace.exit),
        ),
      ),
      ActivationPlace.rTurn ||
      ActivationPlace.rSnap ||
      ActivationPlace.rSave ||
      ActivationPlace.rNuke ||
      ActivationPlace.rLoad ||
      ActivationPlace.rSetT ||
      ActivationPlace.rSetO ||
      ActivationPlace.rRefused => const Within(_inRestore),
      // A file import's HTML decrypted into memory before its webview
      // builds, so the build's synchronous getHtmlSync hits.
      ActivationPlace.html => Step(
        ActivationStep.htmlReply,
        holds: null,
        call: Call.on(
          ActivationFlow.page,
          run: (c) => c.api.ensureSiteHtml(_site.of(c)),
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [],
          next: to(ActivationPlace.commit),
        ),
      ),
      // The preload's back stack queued as its read lands (PAUSE-035): once
      // the site is loaded the activation skips its own read, so this is
      // the only one. It goes on to the jar's turn or its container, or
      // leaves if an input superseded it.
      ActivationPlace.pNav => Step(
        ActivationStep.preloadNavReply,
        holds: null,
        call: Call.on(
          ActivationFlow.queue,
          run: (c) async {
            final target = _site.of(c);
            // restoreState applies only to a freshly created controller.
            if (!target.activeTabPersistsNavState || target.controller != null) {
              return;
            }
            ActivationFlow.state.from(c).navBytes = await c.api.loadState(
              target.stateKeyForTab(_navTab.of(c)),
            );
          },
          writes: [_queuedWrite],
          then: _queueNav,
          reads: _readsAs,
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
          ..._toCookies(StepOutcome.go),
        ],
        otherwise: _toJar(StepOutcome.go),
      ),
      ActivationPlace.space || ActivationPlace.sOnline => _spaceSteps[place]!,
      // The site whose opening a webspace switch superseded goes on loading
      // off screen, from the switch's turn (WEBSPACE-013); the spawn that
      // starts it holds its guard.
      ActivationPlace.keep => Step.spawned(
        ActivationStep.spaceKeep,
        pick: _eachKept,
        site: _eachKept.it,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            kind.becomes(Expr.constant(FlowKind.preload)),
            _site.becomes(_eachKept.it),
            _v.becomes(_version.value),
          ],
          next: to(ActivationPlace.pNav),
        ),
      ),
      // openNested(target): a link opens nested as a site (LIR-011), one at
      // a time. Like a tap it supersedes the activation in flight, which
      // would otherwise load a site beside the screen it never asked about.
      ActivationPlace.nested => Step.input(
        ActivationStep.nestedOpen,
        enabled: _linked.has(_chosen) & _noNestedOpen,
        pick: _eachSite,
        site: _chosen,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            kind.becomes(Expr.constant(FlowKind.nested)),
            _site.becomes(_chosen),
            _v.becomes(_version.value.plus(1)),
            _bump,
          ],
          next: to(ActivationPlace.nSwitch),
        ),
      ),
      // WEBSPACE-012: an open from outside a site shows the target's
      // webspace; one over the site a link came from leaves it alone.
      ActivationPlace.nSwitch => Step(
        ActivationStep.nestedSwitchReply,
        holds: null,
        call: Call.on(
          ActivationFlow.state,
          run: (c) => switch (c.api.opening!) {
            (source: null, :final screen, url: _) => screen.switchWebspaceFor(
              _site.of(c),
            ),
            _ => Future.value(),
          },
          writes: const [],
        ),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(ActivationPlace.nAsk),
        ),
      ),
      // The running sites the screen would repoint go first, asked again
      // after every round of unloads (PROXY-008, TOR-014). A screen whose
      // site shares no proxy scope goes straight up; the Tor exit is
      // process-wide either way, and is pinned to the screen's.
      ActivationPlace.nAsk => Step(
        ActivationStep.nestedAsk,
        holds: null,
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.stale,
            when: _stale,
            then: [],
            next: to(ActivationPlace.exit),
          ),
          Branch(
            StepOutcome.unload,
            when: ~routeFree.call([_site.value]),
            then: _unloadForScreen,
            next: to(ActivationPlace.next),
          ),
          Branch(
            StepOutcome.skip,
            when: ~_contending.has(_site.value),
            then: [_nestedUp, _torPin],
            next: to(ActivationPlace.nUp),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [],
          next: to(ActivationPlace.nApply),
        ),
      ),
      // The proxy moved to the target's route. A newer input supersedes the
      // open; a site that loaded on another route meanwhile sends it back
      // to unload it before the screen goes up.
      ActivationPlace.nApply => Step(
        ActivationStep.nestedApplyReply,
        holds: null,
        site: _site.value,
        call: Call.on(
          ActivationFlow.state,
          run: (c) async {
            try {
              await c.api.opening!.screen.applyProxyOf(_site.of(c));
            } on ProxyRefused catch (e) {
              c.api.refused = true;
              c.api.opening!.screen.reportProxyFailure(e);
            }
          },
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _refused,
            then: [_screenGone],
            next: to(ActivationPlace.exit),
          ),
          Branch(
            StepOutcome.stale,
            when: _stale,
            then: [_screenGone],
            next: to(ActivationPlace.exit),
          ),
          // The claim goes with the round: an input that supersedes the
          // open during it ends the flow at the unload's own check.
          Branch(
            StepOutcome.unload,
            when: ~routeFree.call([_site.value]),
            then: [_screenGone, ..._unloadForScreen],
            next: to(ActivationPlace.next),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            _nestedUp,
            _torPin,
            Note<ActivationFlow>((c) {
              assert(
                _oneRoute.run(c),
                'a nested screen went up beside a site on another route '
                '(PROXY-008)',
              );
            }),
          ],
          next: to(ActivationPlace.nUp),
        ),
      ),
      // The screen is up until it pops; then its site no longer runs. The
      // site on screen, if the open unloaded it, comes back: the flow goes
      // on as its activation (LIR-015, LAZY-007).
      ActivationPlace.nUp => Step(
        ActivationStep.nestedPop,
        holds: null,
        site: _site.value,
        call: Call.on(
          ActivationFlow.state,
          run: (c) => c.api.opening!.screen.launch(_site.of(c), url: c.api.opening!.url),
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.go,
            when: _current.value.neq(_noSite) & ~_loaded.value.has(_current.value),
            then: [
              _nestedDown,
              _screenGone,
              Note((c) => ActivationFlow.state.from(c).plan = null),
              kind.becomes(Expr.constant(FlowKind.tap)),
              _site.becomes(_onScreen),
              _v.becomes(_version.value.plus(1)),
              _markerFor(_onScreen),
              _bump,
              _newestIs,
            ],
            next: Expr.choose(
              when: _noNavState.has(_onScreen),
              then: to(ActivationPlace.plan),
              otherwise: to(ActivationPlace.nav),
            ),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.end,
          then: [_nestedDown, _screenGone],
          next: to(ActivationPlace.done),
        ),
      ),
      // A preload loads its site at the lowest tier and leaves the screen
      // as it is; an activation shows its target. The page shows what this
      // decided, not what its caller last drew.
      ActivationPlace.commit => Step(
        ActivationStep.commit,
        holds: null,
        branches: [
          // Asked again: a nested screen that went up since the input may
          // run on another route (PROXY-008).
          Branch(
            StepOutcome.bail,
            when: _isPreload & ~routeFree.call([_runsAs(_site.value)]),
            then: [],
            next: to(ActivationPlace.exit),
          ),
          Branch(
            StepOutcome.none,
            when: _isPreload,
            then: [
              _tierResident,
              _loadedAdd,
              _preloaded,
              _preloadFramed,
              Note((c) => ActivationFlow.page.from(c).rebuildAndNoteBackground()),
            ],
            next: to(ActivationPlace.exit),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            _showSite,
            _loadedAdd,
            Note((c) => ActivationFlow.page.from(c).rebuild()),
          ],
          next: to(ActivationPlace.resume),
        ),
      ),
      // The target's webview resumes; the activation has committed, so it
      // waits here with its marker still set. Then the sweep: every other
      // loaded webview paused, unawaited, so a frozen page never holds the
      // switch (PAUSE-013 for the probe).
      ActivationPlace.resume => Step(
        ActivationStep.resumeReply,
        holds: null,
        call: Call.on(
          ActivationFlow.page,
          run: (c) => c.api.resume(_site.of(c)),
          writes: const [],
        ),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            _framed,
            Note(
              (c) => ActivationFlow.page.from(c).afterResume(_site.of(c), version: _v.of(c)),
            ),
          ],
          next: to(ActivationPlace.exit),
        ),
      ),
      // The activation's finally: the marker goes only with its own
      // activation, and a screen left on a site with no webview goes home
      // (LAZY-007). A preload owns no marker and sends no screen home.
      ActivationPlace.exit => Step(
        ActivationStep.exit,
        holds: null,
        branches: [
          // Until the jar is emptied and refilled it can hold another
          // same-base-domain site's session (ISO-001), so the target is not
          // shown on it; the user lands on the webspace list (ISO-014).
          Branch(
            StepOutcome.refused,
            when: unrestored.valueOr(none: false) & _is(FlowKind.tap) & ~_stale,
            then: [
              _markerOff,
              _homeOff,
              _newestOff,
              _bailedAfterUnload,
              Note(
                (c) => ActivationFlow.page.from(c).cookiesNotRestored(_site.of(c)),
              ),
            ],
            next: to(ActivationPlace.done),
          ),
          Branch(
            StepOutcome.home,
            when: _screenEmpty,
            then: [_markerOff, _homeOff, _newestOff, _bailedAfterUnload],
            next: to(ActivationPlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.stay,
          then: [_markerOff, _newestOff, _bailedAfterUnload],
          next: to(ActivationPlace.done),
        ),
      ),
      // Going home captured the state of the site it left, bytes only: the
      // webview stays loaded, so a near-immediate return keeps its tab.
      ActivationPlace.hCap => _homeCapture.read,
      ActivationPlace.hCapSave => _homeCapture.save,
      ActivationPlace.hCapUnsave => _homeCapture.unsave,
      // Then the page it left is stopped and paused.
      ActivationPlace.hQuiesce => Step(
        ActivationStep.homeQuiesceReply,
        holds: null,
        call: Call.on(
          ActivationFlow.page,
          run: (c) => c.api.pause(_site.of(c), version: _v.of(c)),
          writes: const [],
        ),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(ActivationPlace.done),
        ),
      ),
      ActivationPlace.done => const Leaves(),
    },
  );
}
