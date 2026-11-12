part of 'tabs_controller.dart';

/// The tab flows' step tables: every place a tab input, a switch, a
/// close, a duplicate, a reroute and a landing can be at, the leaves
/// their guards and writes read, and the definitions they own.
/// [TabsController] runs them; the printer prints them.
abstract final class TabTable {
  // ── The tab flows' leaves: the model's variables as [TabsController] reads
  // them, the flow's fields, and the terms its steps share ──

  /// What a tab flow keeps for itself ([TabState]): code-only, none of
  /// it the model's.
  static final _flow = Port<TabState, TabFlow>(
    'flow',
    reads: const {},
    changes: const {},
    of: (w) => w,
  );

  /// The site the flow's `site` field names, for the code that acts on it:
  /// what the model does not hold of a site.
  static WebViewModel _siteIn(StepView<TabFlow> c) =>
      Port<SiteModels, TabFlow>(
        'sites',
        reads: const {},
        changes: const {},
        of: (w) => w,
      ).from(c).siteOf(_site.of(c));

  /// What the tab steps ask of the page and do to it ([TabCalls]): the
  /// rebinds that finish a switch change the webview's binding and what
  /// is queued for it.
  static final _page = Port<TabCalls, TabFlow>(
    'page',
    reads: const {},
    changes: {ModelVar.built, ModelVar.hist, ModelVar.warm, ModelVar.queued},
    of: (w) => TabCalls(w._c, sites: w),
  );

  /// The openers whose routing switch is on, as a reroute reads them.
  static final _routing =
      Port<List<SiteId> Function(SiteId owner), TabFlow>(
        'routing',
        reads: {ModelVar.tabs, ModelVar.opener},
        changes: const {},
        of: (w) => (owner) => [
          for (final m in w._c.routingOpeners(w.siteOf(owner))) m.siteId,
        ],
      );

  /// The opener a child tab's press named, the flow's own payload
  /// ([TabFlow.namedOpener]): no variable of the model, which picks any
  /// listed site for it (LIR-034).
  static final _childOpeners =
      Port<SiteId? Function(TabState flow), TabFlow>(
        'childOpeners',
        reads: const {},
        changes: const {},
        of: (w) => (flow) => w._c._namedOpener(flow)?.siteId,
      );

  /// What a child tab not listed yet follows, read as [_link] reads a
  /// listed one's (`link`, LIR-034).
  static final _childLinks = Port<ChildLinks, TabFlow>(
    'childLinks',
    reads: {ModelVar.link, ModelVar.host, ModelVar.opener},
    changes: const {},
    of: (w) => ChildLinks(w._c, sites: w),
  );

  /// The tabs' state files, the model's `file` (TAB-003).
  static final _files = Port<WebViewStateStorage, TabFlow>(
    'files',
    reads: {ModelVar.file},
    changes: {ModelVar.file},
    of: (w) => w._c.navStates,
  );

  static Expr<SiteId, TabFlow> get _current => Expr.op(
    HandPaired.tabSiteOnScreen,
    tla: 'current',
    run: (c) => _flow.from(c).site.siteId,
    reads: const Reads(vars: {ModelVar.current}),
  );
  static final _currentVar = Var<SiteId?, TabFlow>(
    ModelVar.current,
    read: (w) => w._c._sites.vars.current.value,
  );
  static final _marker = Var<ActivationMarker<SiteId>?, TabFlow>(
    ModelVar.marker,
    read: (w) => w._c._sites.vars.marker.value,
  );

  static final _nestedVar = Var<SiteId?, TabFlow>(
    ModelVar.nested,
    read: (w) => w._c._sites.vars.nested.value,
  );
  static final _noSite = Expr.constant<SiteId?, TabFlow>(null, tla: '0');

  /// The site [s] is on screen, or the target of the activation in flight.
  static Expr<bool, TabFlow> shownOrTarget(Expr<SiteId, TabFlow> s) =>
      _currentVar.value.eq(s) |
      _marker.value.part('t', get: (m) => m?.target).eq(s);

  /// Where a slot that runs as another site opens again: [shownOrTarget].
  /// Not while a nested screen is up, which runs on its own route and takes
  /// no plan: its pop opens the site on screen as its activation (BUG-037).
  static final reopens = () {
    const s = Bound<SiteId, TabFlow>('s');
    return Def<bool, TabFlow>(
      ModelDef.reopens,
      params: const [s],
      body: shownOrTarget(s.it) & _nestedVar.value.eq(_noSite),
    );
  }();
  static final _reopened = reopens.call([_site.value]);
  static final _loaded = Mutable<Iterable<SiteId>, TabFlow>.over(
    ModelVar.loaded,
    of: (w) => w._c._sites.vars.loaded,
  );
  static final _active = TabVars.active<SiteId, TabFlow>(
    keys: TabVars.ids<TabFlow>(),
  );
  static final _tier = tierOf<TabFlow>();

  /// `tabs[s]` as this controller writes it: the engine's list, whose ids
  /// are the model's set.
  static final _tabs = Indexed<WebViewModel, List<SiteTab>, TabFlow>.over(
    ModelVar.tabs,
    cell: WebViewModel.tabsCell,
  ).keyedBy<SiteId>((w, {required key}) => w.siteOf(key));
  static Expr<List<TabId>, TabFlow> _tabIds(Expr<SiteId, TabFlow> s) =>
      TabVars.tabs<SiteId, TabFlow>(
        keys: TabVars.ids<TabFlow>(),
      ).at(s);

  static const _kind = Field<FlowKind, TabFlow>(FlowField.kind);
  static const _site = Field<SiteId, TabFlow>(FlowField.site);
  static const _tab = Field<TabId, TabFlow>(FlowField.tab);
  static const _keep = Field<bool, TabFlow>(FlowField.keep);
  static const _rest = Field<List<SiteTab>, TabFlow>(FlowField.rest);
  static const _closing = Field<List<TabId>, TabFlow>(FlowField.closing);
  static const _routed = Field<List<SiteId>, TabFlow>(FlowField.routed);
  static const _ranAs = Field<Map<TabId, SiteId>, TabFlow>(
    FlowField.ranAs,
  );
  static const _copy = Field<TabId, TabFlow>(FlowField.copy);
  static const _copyAs = Field<SiteId?, TabFlow>(FlowField.copyAs);
  static const _label = Field<Uint8List?, TabFlow>(FlowField.label);
  static const _wrote = Field<bool, TabFlow>(FlowField.wrote);
  static const _dupView = Field<bool, TabFlow>(FlowField.dupView);

  static final _yes = Expr.constant<bool, TabFlow>(true);
  static final _no = Expr.constant<bool, TabFlow>(false);
  static final _noBytes = Expr.constant<Uint8List?, TabFlow>(null, tla: '0');

  /// The bytes' label, the model's alone: the code holds bytes.
  static final _labelTla = Expr.handPaired<TabId?, TabFlow>(
    HandPaired.tabLabel,
    tla: 'fl[f].label',
    run: (_) => throw StateError('the label is the model\'s'),
    reads: Reads.none,
  );

  /// The input is the site on screen's; the model follows only the sites
  /// a config names (`Tabbed`).
  static final _tabbedCurrent = Expr.op<bool, TabFlow>(
    HandPaired.tabbedOnScreen,
    tla: 'current \\in Tabbed',
    run: (c) => _page.from(c).isShown(_flow.from(c).site.siteId),
    reads: const Reads(vars: {ModelVar.current}),
    needs: const {(of: ModelConst.tabbed, set: true)},
  );

  /// A tab handler holds the gate: the model's `"tab" \in Kinds`.
  static final tabBusy = Def<bool, TabFlow>(
    ModelDef.tabBusy,
    body: Expr.inFlight(FlowKind.tab, run: (c) => _page.from(c).gateBusy),
  );
  static final _dropped = Branch<TabFlow, TabPlace>(
    StepOutcome.busy,
    when: tabBusy.value,
    then: [],
    next: to(TabPlace.done),
  );
  static final _starts = [
    _kind.becomes(Expr.constant(FlowKind.tab)),
    _site.becomes(_current),
  ];

  /// The tab the handler names, among the site's: `\E s \in tabs[current]`.
  static final _eachTab = Pick<TabId, TabFlow>(
    Expr.choose(
      when: _tabbedCurrent,
      then: _tabIds(_current),
      otherwise: Expr.none(),
    ),
    first: (c, {required among}) => _flow.from(c).requested!,
  );
  static final _chosenTab = _eachTab.it;

  /// A fresh tab id (TabId.mint, never repeated): the model's pool.
  static final _hasFresh = Expr.op<bool, TabFlow>(
    HandPaired.hasFreshTab,
    tla: 'HasFresh(current)',
    run: (_) => true,
    reads: const Reads(vars: {ModelVar.current}, base: {BaseOp.hasFresh}),
  );
  static final _mint = Expr.op<TabId, TabFlow>(
    HandPaired.mintOnScreen,
    tla: 'Mint(current)',
    run: (c) => _flow.from(c).fresh!.id,
    reads: const Reads(vars: {ModelVar.current}, base: {BaseOp.mint}),
  );
  static final _mintSite = Expr.op<TabId, TabFlow>(
    HandPaired.mintForSite,
    tla: 'Mint(fl[f].site)',
    run: (c) => _flow.from(c).fresh!.id,
    reads: const Reads(base: {BaseOp.mint}),
  );
  static final _mintedBump = modelOnly<TabFlow>(
    "minted' = [minted EXCEPT ![current] = Mint(current)]",
    writes: {ModelVar.minted},
    reads: const Reads(
      vars: {ModelVar.current, ModelVar.minted},
      base: {BaseOp.mint},
    ),
  );
  static final _mintedBumpSite = modelOnly<TabFlow>(
    "minted' = [minted EXCEPT ![fl[f].site] = Mint(fl[f].site)]",
    writes: {ModelVar.minted},
    reads: const Reads(vars: {ModelVar.minted}, base: {BaseOp.mint}),
  );

  /// The lists the flows install, as the engine orders them, held by their
  /// ids to the model's sets.
  static final _withFresh = Expr.checked(
    rule: _tabIds(_current).union(_mint.asSet),
    run: (c) {
      final f = _flow.from(c);
      return [...f.site.tabs, f.fresh!];
    },
    key: (SiteTab t) => t.id,
    why: "a new tab installs the site's tabs and the fresh one",
  );
  static final _withCopy = Expr.checked(
    rule: _tabIds(_site.value).union(_copy.value.asSet),
    run: (c) => TabLifecycleEngine.insertAfter(
      _flow.from(c).site.tabs,
      anchorId: _tab.of(c),
      tab: _flow.from(c).fresh!,
    ),
    key: (SiteTab t) => t.id,
    why: "a duplicate installs the site's tabs and its copy",
  );

  /// What a close takes with the tab asked for: the model any set of the
  /// site's tabs that holds it, so a subtree (TAB-008) is among them, and
  /// every tab only while the pool has a fresh one to land on; the code the
  /// engine's.
  static final _eachClosed = Pick<List<TabId>, TabFlow>(
    _tabIds(_current).choicesHolding(
      member: _chosenTab,
      whole: _hasFresh,
      taken: (c) => _closeOf(c).closedIds,
    ),
    name: 'shut',
  );

  /// The close the engine decides, once: it moves the survivors up as it
  /// decides, so a second decision would find them moved already.
  static TabCloseResult _closeOf(StepView<TabFlow> c) {
    final f = _flow.from(c);
    return f.result ??= f.subtree
        ? TabLifecycleEngine.closeSubtree(
            f.site.tabs,
            activeTabId: f.site.activeTabId,
            closeId: _chosenTab.run(c),
          )
        : TabLifecycleEngine.closeTab(
            f.site.tabs,
            activeTabId: f.site.activeTabId,
            closeId: _chosenTab.run(c),
          );
  }

  static final _resultTabs = Expr.checked(
    rule: _tabIds(_current).less(_eachClosed.it),
    run: (c) => _flow.from(c).result!.tabs,
    key: (SiteTab t) => t.id,
    why: "a close installs the site's tabs but the ones it takes",
  );
  static final _survivors = _tabIds(_current).without(_chosenTab);
  static final _restIds = Expr.handPaired<List<TabId>, TabFlow>(
    HandPaired.restTabIds,
    tla: 'fl[f].rest',
    run: (c) => _rest.isSet(c) ? [for (final t in _rest.of(c)) t.id] : const [],
    reads: Reads.none,
  );
  static final _onlyFresh = Expr.checked(
    rule: _mintSite.asSet,
    run: (c) => [_flow.from(c).fresh!],
    key: (SiteTab t) => t.id,
    why: 'a last close leaves the fresh tab alone',
  );
  static final _installed = Expr.handPaired<List<SiteTab>, TabFlow>(
    HandPaired.installedTabs,
    tla: 'IF fl[f].rest = {} THEN tabs[fl[f].site] ELSE fl[f].rest',
    run: (c) => _rest.isSet(c) ? _rest.of(c) : _flow.from(c).site.tabs,
    reads: const Reads(vars: {ModelVar.tabs}),
  );

  /// The tabs the target has to be among: the list being installed, else
  /// the site's. A page gone away has none.
  static final _targetIn = Expr.handPaired<List<TabId>, TabFlow>(
    HandPaired.targetAmong,
    tla: 'IF fl[f].rest = {} THEN tabs[fl[f].site] ELSE fl[f].rest',
    run: (c) => !_page.from(c).mounted
        ? const []
        : _rest.isSet(c)
        ? [for (final t in _rest.of(c)) t.id]
        : [for (final t in _flow.from(c).site.tabs) t.id],
    reads: const Reads(vars: {ModelVar.tabs}),
  );
  static SiteTab? _targetOf(StepView<TabFlow> c) {
    final id = _tab.of(c);
    for (final t in _rest.isSet(c) ? _rest.of(c) : _flow.from(c).site.tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// A close's rebind, whose closed tabs' files go after it; a switch
  /// closes none.
  static final _closes = ~_closing.valueOr(none: const []).isEmpty;

  /// The rebind of a slot whose identity changes across a rule another
  /// site shares: it leaves the loaded sites, and its activation for the
  /// new route starts in the same turn (LIR-024).
  static final List<Effect<TabFlow>> _rebindsAs = [
    Act.of([
      _active.except(_site.value, to: _tab.value),
      _tabs.except(_site.value, to: _installed),
      ...TabVars.dropped(_site.value, kept: _targetIn, keys: TabVars.ids()),
      _loaded.becomes(_loaded.value.less(_site.value.asSet)),
      ...TabVars.rebound(
        _site.value,
        keys: TabVars.ids(),
        tab: _tab.value,
        label: _labelTla,
        loaded: _loaded.value.less(_site.value.asSet),
        warmth: const DropsWarm(),
      ),
    ], then: (c) => _page.from(c).rebindAs(c)),
    Spawn(
      ActivationStep.tap,
      site: _site.value,
      when: _reopened,
      start: (c) => _page.from(c).activate(_site.of(c)),
    ),
  ];

  /// The tabs whose views are warm once the switch shows its target,
  /// before the limit (TAB-023).
  static final warmAfterNow = TabVars.warmAfter<SiteId, TabFlow>(keys: TabVars.ids<TabFlow>()).call([
    _site.value,
    _tab.value,
    _targetIn,
  ]);

  /// A tap or a preload is about to add a site the views it counted did
  /// not hold a warm view for (TAB-024).
  static final _sitesJoin =
      Expr.inFlight<TabFlow>(
        FlowKind.tap,
        run: (c) => _page.from(c).flowInFlight(FlowKind.tap),
      ) |
      Expr.inFlight<TabFlow>(
        FlowKind.preload,
        run: (c) => _page.from(c).flowInFlight(FlowKind.preload),
      );

  /// The warm view a switch's limit lets go of, or none (TAB-023).
  static final warmVictim = TabVars.warmVictim<SiteId, TabFlow>(
    _site.value,
    keys: TabVars.ids<TabFlow>(),
    tab: _tab.value,
    kept: _targetIn,
    joining: _sitesJoin,
    limits: (
      own: Constant<int, TabFlow>(
        ModelConst.warmOwn,
        read: (w) => w._c.residency.warmLimits.own,
      ).value,
      hosted: Constant<int, TabFlow>(
        ModelConst.warmHosted,
        read: (w) => w._c.residency.warmLimits.hosted,
      ).value,
    ),
    loaded: _loaded.value,
    maxLoaded: Constant<int, TabFlow>(
      ModelConst.maxLoaded,
      read: (w) => w._c.residency.caps.loaded,
    ).value,
    tabsOf: (c) => _flow.from(c).site.tabs,
    shownOf: (c) => _flow.from(c).site.tabBinding.built,
  );

  /// List, pointer and webview moved in one turn; the view shown before
  /// stays warm as the limit lets it (TAB-023).
  static final List<Effect<TabFlow>> _rebinds = [
    Act.of([
      _active.except(_site.value, to: _tab.value),
      _tabs.except(_site.value, to: _installed),
      ...TabVars.dropped(_site.value, kept: _targetIn, keys: TabVars.ids()),
      _tier.except(_site.value, to: _residentIfLoaded),
      ...TabVars.rebound(
        _site.value,
        keys: TabVars.ids(),
        tab: _tab.value,
        label: _labelTla,
        loaded: _loaded.value,
        warmth: KeepsWarm(kept: _targetIn, victim: warmVictim.it),
      ),
    ], then: (c) => _page.from(c).rebind(c)),
  ];

  static final _live =
      _currentVar.value.eq(_site.value) | _loaded.value.has(_site.value);

  /// The duplicate's source is still the site's (and the page is there).
  static final _sourceStays = Expr.handPaired<bool, TabFlow>(
    HandPaired.duplicateSourceStays,
    tla: 'fl[f].tab \\in tabs[fl[f].site]',
    run: (c) =>
        _page.from(c).mounted &&
        _flow.from(c).site.tabs.any((t) => t.id == _tab.of(c)),
    reads: const Reads(vars: {ModelVar.tabs}),
  );
  static final _residentIfLoaded = Expr.choose<SiteLifecycleState, TabFlow>(
    when: _loaded.value.has(_site.value),
    then: Expr.constant(SiteLifecycleState.resident, tla: '"resident"'),
    otherwise: _tier.at(_site.value),
  );
  static final _eachClosing = Pick<TabId, TabFlow>(_closing.value, name: 'x');
  static final _nextSurvivor = Pick<TabId, TabFlow>(
    _restIds,
    name: 'next',
    first: (c, {required among}) =>
        _flow.from(c).result?.nextActiveId ?? among.first,
  );

  /// LIR-024: a tab switch whose target runs as another site than the
  /// slot does, across a rule another site shares ([movesRule]), where the
  /// slot leaves the loaded sites. Only under containers does a tab run as
  /// another site ([mayHost]).
  static final _identityChanges =
      _containers &
      _tabHost.at(_site.value).at(_tab.value).neq(_runsAs(_site.value)) &
      movesRule.call([
        _runsAs(_site.value),
        _tabHost.at(_site.value).at(_tab.value),
      ]);

  static final _containers = Constant<bool, TabFlow>(
    ModelConst.containers,
    read: (w) => w._c._sites.useContainers,
  ).value;
  static final _sitesListed = Constant<List<SiteId>, TabFlow>(
    ModelConst.sites,
    read: (w) => [for (final m in w._c._sites.models) m.siteId],
  ).value;
  static final _noLink = Expr.constant<SiteId?, TabFlow>(null, tla: '0');

  /// The listed tabs of [s] a link opened that some reading of the
  /// switches moves (LIR-034): one with two places, its link's site and
  /// its opener, or one that runs at neither.
  static Expr<List<TabId>, TabFlow> _relinked(Expr<SiteId, TabFlow> s) {
    const l = Bound<TabId, TabFlow>('l');
    final by = _opener.at(s).at(l.it);
    return _tabIds(s).where(
      l,
      holds:
          by.neq(_noLink) &
          ~(_link.at(s).at(l.it).eq(by) & by.eq(_tabHost.at(s).at(l.it))),
    );
  }

  /// Where tab [t] of [s] runs while the openers [routed] route outbound
  /// links and the rest do not: its link's site, or its opener.
  static Expr<SiteId, TabFlow> _placeOf(
    Expr<SiteId, TabFlow> s, {
    required Expr<TabId, TabFlow> t,
    required Expr<Iterable<SiteId>, TabFlow> routed,
  }) => Expr.choose(
    when: routed.has(_opener.at(s).at(t)),
    then: _link.at(s).at(t).unwrapped,
    otherwise: _opener.at(s).at(t).unwrapped,
  );

  /// The tabs of [s] a link opened that run elsewhere than [_placeOf] puts
  /// them while the openers `R` route (`Misplaced`): the reroute picks a
  /// reading that leaves one out of place, and its flip moves them.
  static final misplaced = () {
    const s = Bound<SiteId, TabFlow>('s');
    const routed = Bound<Iterable<SiteId>, TabFlow>('R');
    const l = Bound<TabId, TabFlow>('l');
    return Def<List<TabId>, TabFlow>(
      ModelDef.misplaced,
      params: const [s, routed],
      body: _tabIds(s.it).where(
        l,
        holds:
            _opener.at(s.it).at(l.it).neq(_noLink) &
            _tabHost
                .at(s.it)
                .at(l.it)
                .neq(_placeOf(s.it, t: l.it, routed: routed.it)),
      ),
    );
  }();
  static Expr<List<TabId>, TabFlow> _misplaced(
    Expr<SiteId, TabFlow> s, {
    required Expr<Iterable<SiteId>, TabFlow> routed,
  }) => misplaced.call([s, routed]);

  /// A site whose switch-following tabs may move: one whose tabs the model
  /// follows (`Tabbed`) with a tab that has two places.
  static final _eachRerouted = () {
    const o = Bound<SiteId, TabFlow>('o');
    // Not `s`: the activation its slot's arm spawns binds that.
    return Pick<SiteId, TabFlow>(
      _sitesListed.where(
        o,
        holds:
            TabVars.tabbed<SiteId, TabFlow>().has(o.it) &
            _relinked(o.it).isNotEmpty,
      ),
      first: (c, {required among}) => _flow.from(c).site.siteId,
      name: 'r',
    );
  }();
  static final _rerouted = _eachRerouted.it;

  /// The openers of the rerouted site's tabs whose switch is on: the model
  /// takes any set of them that leaves a tab out of place, the code the
  /// ones it read on (LIR-013).
  static final _eachRouted = () {
    const o = Bound<SiteId, TabFlow>('o');
    const l = Bound<TabId, TabFlow>('l');
    const x = Bound<List<SiteId>, TabFlow>('R');
    final openers = _sitesListed.where(
      o,
      holds: _tabIds(
        _rerouted,
      ).where(l, holds: _opener.at(_rerouted).at(l.it).eq(o.it)).isNotEmpty,
    );
    return Pick<List<SiteId>, TabFlow>(
      openers.choicesWhere(
        x,
        holds: _misplaced(_rerouted, routed: x.it).isNotEmpty,
        taken: (c) => _routing.from(c)(_rerouted.run(c)),
      ),
      name: 'rt',
    );
  }();

  /// The sites with tabs a reset lands at home (TAB-014).
  static final _eachLanded = Pick<SiteId, TabFlow>(
    Expr.op(
      HandPaired.landedSites,
      tla: r'Listed \cap Resettable \cap Tabbed',
      run: (c) => [_flow.from(c).site.siteId],
      reads: const Reads(base: {BaseOp.listed}),
      needs: const {
        (of: ModelConst.resettable, set: true),
        (of: ModelConst.tabbed, set: true),
      },
    ),
  );
  static final _landed = _eachLanded.it;

  /// The sites with tabs an owner-run move may take (LIR-018): the engine
  /// asks for one only for a site whose slot runs as another, or on a tab
  /// anchored in another domain, which the model does not follow.
  static final _eachOwnerRun = Pick<SiteId, TabFlow>(
    Expr.op(
      HandPaired.ownerRunSites,
      tla: r'Listed \cap Tabbed',
      run: (c) => [_flow.from(c).site.siteId],
      reads: const Reads(base: {BaseOp.listed}),
      needs: const {(of: ModelConst.tabbed, set: true)},
    ),
  );
  static final _ownerRunning = _eachOwnerRun.it;

  /// The site with tabs a child tab opens in, while the model's pool has
  /// a fresh tab id for it.
  static final _eachChildOwner = Pick<SiteId, TabFlow>(
    Expr.op(
      HandPaired.childSites,
      tla: r'{o \in Listed \cap Tabbed : HasFresh(o)}',
      run: (c) => [_flow.from(c).site.siteId],
      reads: const Reads(base: {BaseOp.listed, BaseOp.hasFresh}),
      needs: const {(of: ModelConst.tabbed, set: true)},
    ),
  );
  static final _childOwner = _eachChildOwner.it;

  /// The site a child tab runs as: another listed site where containers
  /// keep their cookies apart (LIR-032), else its own.
  static final _eachChildHost = Pick<SiteId, TabFlow>(
    Expr.op(
      HandPaired.childHosts,
      tla: r'IF Containers THEN Listed ELSE {fl[f].site}',
      run: (c) => [
        _page.from(c).childHost(_flow.from(c).fresh!, owner: _site.of(c)),
      ],
      reads: const Reads(base: {BaseOp.listed}),
    ),
    name: 'hs',
  );

  /// What a child tab follows while its opener routes outbound links
  /// (LIR-034): a listed site where its handler named an opener at its
  /// input ([_eachChildOpener]), none (`0`) for one no link opened.
  static final _eachChildLink = Pick<SiteId?, TabFlow>(
    Expr.op(
      HandPaired.childLinks,
      tla: r'IF fl[f].copyAs = 0 THEN {0} ELSE Listed',
      run: (c) => [
        _childLinks.from(c).of(_flow.from(c).fresh!, owner: _site.of(c)),
      ],
      reads: const Reads(
        vars: {ModelVar.link, ModelVar.host},
        base: {BaseOp.listed},
      ),
    ),
    name: 'lk',
  );

  /// The site whose switch a child tab follows, which its handler names as
  /// the link is pressed, before a park waits for a free gate (TAB-006).
  static final _eachChildOpener = Pick<SiteId?, TabFlow>(
    Expr.op(
      HandPaired.childOpeners,
      tla: r'{0} \cup Listed',
      run: (c) => [_childOpeners.from(c)(_flow.from(c))],
      reads: const Reads(base: {BaseOp.listed}),
    ),
    name: 'op',
  );

  /// Whether the close kept the tab's history: the model either, the code
  /// whether its removal took any bytes.
  static final _eachKept = Pick<bool, TabFlow>(
    Expr.constant(const [true, false], tla: 'BOOLEAN'),
    name: 'kept',
    first: (c, {required among}) =>
        _flow.from(c).reopening?.history?.isNotEmpty ?? false,
  );
  static final _withReopened = Expr.checked(
    rule: _tabIds(_site.value).union(_copy.value.asSet),
    run: (c) => TabLifecycleEngine.reopen(
      _siteIn(c).tabs,
      tab: _flow.from(c).fresh!,
      closed: _flow.from(c).reopening!,
    ),
    key: (SiteTab t) => t.id,
    why: "a reopen installs the site's tabs and the reopened one",
  );
  static final _withChild = Expr.checked(
    rule: _tabIds(_site.value).union(_mintSite.asSet),
    run: (c) => TabLifecycleEngine.insertChild(
      _siteIn(c).tabs,
      tab: _flow.from(c).fresh!,
    ),
    key: (SiteTab t) => t.id,
    why: "a child tab joins its site's list",
  );

  /// The tab a landing names: the one the site is on, a parked one, or a
  /// fresh one while the pool has one; the engine decides which.
  static final _eachLanding = Pick<TabId, TabFlow>(
    Expr.op(
      HandPaired.landingTabs,
      tla:
          r'tabs[fl[f].site] \cup '
          r'(IF HasFresh(fl[f].site) THEN {Mint(fl[f].site)} ELSE {})',
      run: (c) => [for (final t in _flow.from(c).landed!) t.id],
      reads: const Reads(
        vars: {ModelVar.tabs},
        base: {BaseOp.hasFresh, BaseOp.mint},
      ),
    ),
    first: (c, {required among}) => _flow.from(c).requested!,
  );
  static final _landing = _eachLanding.it;
  static final _landedTabs = Expr.checked(
    rule: _tabIds(_site.value).union(_landing.asSet),
    run: (c) => _flow.from(c).landed!,
    key: (SiteTab t) => t.id,
    why: "a landing installs the site's tabs and the one it names",
  );
  static final _landedMint = modelOnly<TabFlow>(
    "minted' = IF s = Mint(fl[f].site) "
    "THEN [minted EXCEPT ![fl[f].site] = Mint(fl[f].site)] ELSE minted",
    writes: {ModelVar.minted},
    reads: const Reads(vars: {ModelVar.minted}, base: {BaseOp.mint}),
  );

  /// Each of [s]'s tabs out of place runs where its opener's switch, as
  /// the reroute read it, puts it.
  static Write<TabFlow> _flip(Expr<SiteId, TabFlow> s) {
    const t = Bound<TabId, TabFlow>('t');
    final host = TabVars.hostFn<SiteId, TabFlow>();
    return host.becomes(
      host.value.except(
        s,
        to: host.value
            .at(s)
            .exceptEach(
              _misplaced(s, routed: _routed.value),
              x: t,
              to: _placeOf(s, t: t.it, routed: _routed.value),
            ),
      ),
    );
  }

  /// The loaded sites as a reroute's flips found them.
  static final _beforeReroute = Note<TabFlow>(
    (c) => _flow.from(c).loadedBefore = _page.from(c).loaded,
  );

  /// The tab on screen is one the reroute flips: the slot runs as another
  /// site.
  static final _slotFlips = _misplaced(
    _site.value,
    routed: _routed.value,
  ).has(_active.at(_site.value));

  /// `Contending`: the sites in a proxy scope another site's activation
  /// repoints, every one under one process-wide proxy and the router's
  /// shared session under the router.
  static final contending = Members<SiteId, TabFlow>(
    ModelConst.contending,
    test: (w, {required member}) =>
        w._c.residency.proxyTopology.contends(w.siteOf(member)),
  );
  static final globalProxy = Constant<bool, TabFlow>(
    ModelConst.globalProxy,
    read: (w) => TabCalls(w._c, sites: w).processGlobal,
  ).value;
  static final torRuntime = Constant<bool, TabFlow>(
    ModelConst.torRuntime,
    read: (w) => TabCalls(w._c, sites: w).torRuntime,
  ).value;

  /// Whether a slot that runs as `a` and comes to run as `b` moves a rule
  /// another running site shares: a proxy scope either contends in, or the
  /// one Tor runtime's exit (PROXY-008, TOR-014). The slot then leaves the
  /// loaded sites, and its activation's plan unloads what its new route
  /// would move; the code's flips outside a step read [TabCalls.movesRule].
  static final movesRule = () {
    const a = Bound<SiteId, TabFlow>('a');
    const b = Bound<SiteId, TabFlow>('b');
    return Def<bool, TabFlow>(
      ModelDef.movesRule,
      params: const [a, b],
      body: contending.has(a.it) | contending.has(b.it) | torRuntime,
    );
  }();

  /// The site [s]'s slot runs as once a reroute flips its tab on screen.
  static Expr<SiteId, TabFlow> _flippedAs(
    Expr<SiteId, TabFlow> s,
  ) => _placeOf(s, t: _active.at(s), routed: _routed.value);
  static final _tabHost = TabVars.host<SiteId, TabFlow>(
    keys: TabVars.ids<TabFlow>(),
  );
  static Expr<SiteId, TabFlow> _runsAs(Expr<SiteId, TabFlow> s) =>
      TabVars.runsAs<SiteId, TabFlow>(
        keys: TabVars.ids<TabFlow>(),
      ).call([s]);

  /// `link[s]` as the code reads it: the site each link tab runs as while
  /// its opener routes outbound links ([linkHosts]).
  static final _link =
      Indexed<SiteId, Map<TabId, SiteId?>, TabFlow>.reported(
        ModelVar.link,
        read: (w, {required at}) => {
          for (final MapEntry(:key, :value)
              in w._c.linkHosts(w.siteOf(at)).entries)
            key: value?.siteId,
        },
      );

  /// `opener[s]` as the code reads it: the listed site whose switch each
  /// link tab follows ([linkOpeners]).
  static final _opener =
      Indexed<SiteId, Map<TabId, SiteId?>, TabFlow>.reported(
        ModelVar.opener,
        read: (w, {required at}) => {
          for (final MapEntry(:key, :value)
              in w._c.linkOpeners(w.siteOf(at)).entries)
            key: value?.siteId,
        },
      );

  static String _copyKey(StepView<TabFlow> c) {
    final copy = _flow.from(c).fresh!;
    return webViewStateKey(
      copy.hostSiteId ?? _site.of(c),
      tabId: copy.id,
    );
  }

  // ── The tab flows as a step table (TAB-003), printed into activation.tla ──

  /// A tab input on the site on screen and the switch, close and duplicate
  /// it runs, between their awaits: [tabInputs] for the inputs, which run
  /// before any await and outside the gate, [tabFlow] for the rest, under
  /// the gate. A tab input on a site off screen takes the handler's other
  /// path (an activation inside the gate), which the model does not hold.
  static final tabInputs = StepTable<TabFlow, TabPlace>(
    TabPlace.values,
    ending: {TabPlace.done},
    at: (place) => switch (place) {
      // openTab(site, tabId): on the site on screen, a switch to the tab;
      // the one it is on already is nothing; dropped while a handler runs.
      TabPlace.openTab => Step.input(
        ActivationStep.openTab,
        enabled: _tabbedCurrent,
        pick: _eachTab,
        site: _current,
        tab: _chosenTab,
        branches: [
          _dropped,
          Branch(
            StepOutcome.stay,
            when: _chosenTab.eq(_active.at(_current)),
            then: [],
            next: to(TabPlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [..._starts, _tab.becomes(_chosenTab), _keep.becomes(_yes)],
          next: to(TabPlace.tCap),
        ),
      ),
      // newTab(site): a fresh tab at the site's home joins the list, and the
      // switch parks the tab the site was on (TAB-005).
      TabPlace.newTab => Step.input(
        ActivationStep.newTab,
        enabled: _tabbedCurrent & _hasFresh,
        site: _current,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            Note((c) {
              final f = _flow.from(c);
              f.fresh = SiteTab(url: f.url ?? f.site.initUrl);
            }),
            Act.of([_tabs.except(_current, to: _withFresh)]),
            _mintedBump,
            ..._starts,
            _tab.becomes(_mint),
            _keep.becomes(_yes),
          ],
          next: to(TabPlace.tCap),
        ),
      ),
      // closeTab(site, tabId): the engine decides the survivors and the tab
      // that takes over, and each closed tab's key is kept: its file goes
      // once the list has let it go (tRemove), so a capture of it still
      // out finds it gone and takes back what it saves (TAB-003).
      TabPlace.closeTab => Step.input(
        ActivationStep.closeTab,
        enabled: _tabbedCurrent & (~_survivors.isEmpty | _hasFresh),
        pick: _eachTab,
        site: _current,
        tab: _chosenTab,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          pick: _eachClosed,
          then: [
            Note((c) {
              final f = _flow.from(c);
              final result = _closeOf(c);
              f.dropped = {
                for (final id in result.closedIds)
                  id: f.site.stateKeyForTab(id),
              };
              f.closed = TabLifecycleEngine.closedFrom(
                f.site.tabs,
                site: f.site.siteId,
                result: result,
              );
            }),
            ..._starts,
            _tab.becomes(_chosenTab),
            _keep.becomes(_no),
            _rest.becomes(_resultTabs),
            _closing.becomes(_eachClosed.it),
            _ranAs.becomes(_tabHost.at(_current)),
          ],
          next: to(TabPlace.tClosed),
        ),
      ),
      // duplicateTab(site): a copy of the active tab, parked beside it
      // (TAB-010); its back stack is read first, then written to the copy.
      TabPlace.duplicateTab => Step.input(
        ActivationStep.duplicateTab,
        enabled: _tabbedCurrent & _hasFresh,
        site: _current,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            Note((c) {
              final f = _flow.from(c);
              f.fresh = TabsController._copyOf(f.site.activeTab);
            }),
            _mintedBump,
            ..._starts,
            _tab.becomes(_active.at(_current)),
            _copy.becomes(_mint),
            _copyAs.becomes(_runsAs(_current)),
          ],
          next: to(TabPlace.tDupRead),
        ),
      ),
      // reroute: a site's routing switch flipped as its settings closed
      // (LIR-034): the link tabs it opened in its own tree are to run as
      // the site their link leads to, or as it again (rFlip, in this turn),
      // and their old files go next (rRemove). Asked while a handler holds
      // the gate, it waits for it to let go, which the model takes as one
      // dropped now and one landing then.
      TabPlace.reroute => Step.input(
        ActivationStep.reroute,
        enabled: _containers,
        pick: _eachRerouted,
        site: _rerouted,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          pick: _eachRouted,
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_rerouted),
            _routed.becomes(_eachRouted.it),
            _closing.becomes(_misplaced(_rerouted, routed: _eachRouted.it)),
            _ranAs.becomes(_tabHost.at(_rerouted)),
          ],
          next: to(TabPlace.rFlip),
        ),
      ),
      // homeLanding(site): a reset lands a site with tabs at home
      // (TAB-014), the tab it names chosen next (hLand); dropped while a
      // handler runs.
      TabPlace.homeLanding => Step.input(
        ActivationStep.homeLanding,
        pick: _eachLanded,
        site: _landed,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_landed),
          ],
          next: to(TabPlace.hLand),
        ),
      ),
      // ownerRun(site): before an owner URL loads, the slot moves to a tab
      // the site runs itself, chosen next (oLand) as a landing's is. It
      // lands only on a free gate: the code waits for one, since the move
      // may not be dropped (LIR-034).
      TabPlace.ownerRun => Step.input(
        ActivationStep.ownerRun,
        enabled: ~tabBusy.value,
        pick: _eachOwnerRun,
        site: _ownerRunning,
        branches: [],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_ownerRunning),
          ],
          next: to(TabPlace.oLand),
        ),
      ),
      // childTab(site): a link or a search opens a child tab of a site
      // with tabs, inserted at its landing (cLand) and switched to;
      // dropped while a handler runs.
      TabPlace.childTab => Step.input(
        ActivationStep.childTab,
        pick: _eachChildOwner,
        site: _childOwner,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          pick: _eachChildOpener,
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_childOwner),
            _copyAs.becomes(_eachChildOpener.it),
          ],
          next: to(TabPlace.cLand),
        ),
      ),
      // parkChild(site): a long-pressed link or Back opens a parked child,
      // inserted at its landing (pLand). It lands only on a free gate: the
      // code waits for one, since the insert may not be lost (TAB-006).
      TabPlace.parkChild => Step.input(
        ActivationStep.parkChild,
        enabled: ~tabBusy.value,
        pick: _eachChildOwner,
        site: _childOwner,
        otherwise: Otherwise(
          StepOutcome.go,
          pick: _eachChildOpener,
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_childOwner),
            _copyAs.becomes(_eachChildOpener.it),
          ],
          next: to(TabPlace.pLand),
        ),
      ),
      // reopenTab(site): a closed tab back with its history (TAB-022): its
      // landing fixes the site it runs as and its id (reLand), its file is
      // written back (reSave) and it joins the list (reInsert). It lands
      // only on a free gate: the code waits for one, since an undo may not
      // be lost.
      TabPlace.reopenTab => Step.input(
        ActivationStep.reopenTab,
        enabled: ~tabBusy.value,
        pick: _eachChildOwner,
        site: _childOwner,
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_childOwner),
          ],
          next: to(TabPlace.reLand),
        ),
      ),
      TabPlace.tCap ||
      TabPlace.tCapSave ||
      TabPlace.tNav ||
      TabPlace.tRebind ||
      TabPlace.tClosed ||
      TabPlace.tRemove ||
      TabPlace.tDupRead ||
      TabPlace.tDupSave ||
      TabPlace.tDupInsert ||
      TabPlace.tDupRemove ||
      TabPlace.rFlip ||
      TabPlace.rRemove ||
      TabPlace.hLand ||
      TabPlace.oLand ||
      TabPlace.cLand ||
      TabPlace.cOpen ||
      TabPlace.pLand ||
      TabPlace.reLand ||
      TabPlace.reSave ||
      TabPlace.reInsert ||
      TabPlace.done => const Leaves(),
    },
  );

  /// The outgoing tab's back stack captured under the webview's tab, in
  /// the capture's steps; a target tab that left the list meanwhile ends
  /// the switch first. The switch holds the tab gate, so no close or
  /// reroute moves the tab while the save is out: no unsave.
  static final _capture = captureSteps<SiteId, TabFlow, TabPlace>(
    names: (
      read: ActivationStep.tabCaptureReply,
      save: ActivationStep.tabCaptureSave,
    ),
    places: (save: TabPlace.tCapSave, after: to(TabPlace.tNav)),
    unsave: null,
    of: (
      site: _site.value,
      built: (w, {required site}) => w.siteOf(site).tabBinding.built,
      hosts: (w, {required site}) => w.siteOf(site).tabHostIds,
      begin: (c) => _page.from(c).beginCapture(_site.of(c)),
      marks: _site.value,
      keeps: null,
    ),
    first: [
      Branch(
        StepOutcome.gone,
        when: ~_targetIn.has(_tab.value),
        then: [],
        next: to(TabPlace.done),
      ),
    ],
  );

  static final tabFlow = StepTable<TabFlow, TabPlace>(
    TabPlace.values,
    ending: {TabPlace.done},
    vars: [_loaded, _currentVar],
    at: (place) => switch (place) {
      TabPlace.openTab ||
      TabPlace.newTab ||
      TabPlace.closeTab ||
      TabPlace.duplicateTab ||
      TabPlace.reroute ||
      TabPlace.homeLanding ||
      TabPlace.ownerRun ||
      TabPlace.childTab ||
      TabPlace.parkChild ||
      TabPlace.reopenTab ||
      TabPlace.done => const Leaves(),
      // The outgoing tab's back stack captured under the webview's tab
      // (Capture); a target closed meanwhile ends the switch.
      TabPlace.tCap => _capture.read,
      TabPlace.tCapSave => _capture.save,
      // The target's saved back stack read; then list, pointer and webview
      // move in one turn (tRebind), unless the slot's identity changes
      // under a process-global proxy (LIR-024), which moves the pointer
      // first and awaits the reroute.
      TabPlace.tNav => Step(
        ActivationStep.tabNavReply,
        holds: null,
        call: _label.receivesOn(
          _files,
          run: (c) async {
            final site = _siteIn(c);
            final incoming = _targetOf(c);
            if (incoming == null || !site.tabPersistsNavState(incoming)) {
              return null;
            }
            return c.api.loadState(
              webViewStateKey(
                incoming.hostSiteId ?? site.siteId,
                tabId: incoming.id,
              ),
            );
          },
          reply: TabVars.savedFor(
            _site.value,
            tab: _tab.value,
            keys: TabVars.ids(),
          ),
        ),
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.gone,
            when: ~_targetIn.has(_tab.value),
            then: [],
            next: to(TabPlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [],
          next: to(TabPlace.tRebind),
        ),
      ),
      // List, pointer and webview move in one turn: the bytes read are
      // queued for the target, the old webview goes, the rebuild frame
      // builds one for the target from them (TAB-003). A target that runs
      // as another site across a rule another site shares takes the slot out of
      // the loaded sites in the same turn, and the site's activation for its
      // new route starts in that turn too, the arm's spawn (LIR-024). A
      // close's rebind goes on to its closed tabs' files.
      TabPlace.tRebind => Step(
        ActivationStep.tabRebind,
        holds: null,
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.unload,
            when: _identityChanges & _closes,
            then: _rebindsAs,
            next: to(TabPlace.tRemove),
          ),
          Branch(
            StepOutcome.unload,
            when: _identityChanges,
            then: _rebindsAs,
            next: to(TabPlace.done),
          ),
          Branch(
            StepOutcome.none,
            when: _closes,
            pick: warmVictim,
            then: _rebinds,
            next: to(TabPlace.tRemove),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.none,
          pick: warmVictim,
          then: _rebinds,
          next: to(TabPlace.done),
        ),
      ),
      // The close decided: the site left with no tab lands on a fresh one
      // at home, a closed active tab hands the webview to the engine's next,
      // a parked one just leaves the list. A closed tab on screen is
      // captured first (tCap), so its history is in its file for the
      // removal to keep (TAB-022). The closed tabs' files go after.
      TabPlace.tClosed => Step(
        ActivationStep.tabClosed,
        holds: null,
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.rebind,
            when: _restIds.isEmpty,
            then: [
              Note(
                (c) => _flow.from(c).fresh = SiteTab(url: _siteIn(c).initUrl),
              ),
              _mintedBumpSite,
              _tab.becomes(_mintSite),
              _rest.becomes(_onlyFresh),
            ],
            next: to(TabPlace.tCap),
          ),
          Branch(
            StepOutcome.rebind,
            when: _closing.value.has(_active.at(_site.value)) & _live,
            pick: _nextSurvivor,
            tab: _nextSurvivor.it,
            then: [_tab.becomes(_nextSurvivor.it)],
            next: to(TabPlace.tCap),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.end,
          pick: _nextSurvivor,
          tab: _nextSurvivor.it,
          then: [
            Act.of([
              _tabs.except(_site.value, to: _rest.value),
              ...TabVars.dropped(
                _site.value,
                kept: _restIds,
                keys: TabVars.ids(),
              ),
              TabVars.warmGone(
                _site.value,
                keys: TabVars.ids(),
                tabs: _closing.value,
              ),
              _active.except(
                _site.value,
                to: Expr.choose(
                  when: _closing.value.has(_active.at(_site.value)),
                  then: _nextSurvivor.it,
                  otherwise: _active.at(_site.value),
                ),
              ),
            ], then: (c) => _page.from(c).closed(c)),
          ],
          next: to(TabPlace.tRemove),
        ),
      ),
      // A closed tab's file removed under the key it had as the close began,
      // one a step, once no list holds it; its bytes are kept in memory for
      // a reopen (TAB-022), so no file outlives its tab.
      TabPlace.tRemove => Step(
        ActivationStep.tabRemoveReply,
        holds: null,
        pick: _eachClosing,
        call: Call.on(
          _files,
          run: (c) async {
            final id = _eachClosing.it.run(c);
            final flow = _flow.from(c);
            final bytes = await c.api.takeState(flow.dropped[id]!);
            if (bytes != null) flow.taken[id] = bytes;
          },
          writes: [
            TabVars.removedAs(
              _site.value,
              tab: _eachClosing.it,
              as: _ranAs.value.at(_eachClosing.it),
            ),
          ],
        ),
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.more,
            when: ~_closing.value.without(_eachClosing.it).isEmpty,
            then: [_closing.becomes(_closing.value.without(_eachClosing.it))],
            next: to(TabPlace.tRemove),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.end,
          then: [],
          next: to(TabPlace.done),
        ),
      ),
      // The duplicate's source read: the webview's back stack when the
      // site is loaded and the webview is the source's, else its file.
      // Which, and the webview's bytes, are decided as the read starts, so
      // a delete that drops the site while it is out leaves them; the file
      // is the store's to read while the call is out.
      TabPlace.tDupRead => Step(
        ActivationStep.dupReadReply,
        holds: null,
        call: _label.receivesOn(
          _files,
          reads: [
            _dupView.fromPlatform(_loaded.value.has(_site.value)),
            _label.fromPlatform(
              Expr.choose(
                when: _loaded.value.has(_site.value),
                then: TabVars.dupShown(
                  _site.value,
                  source: _tab.value,
                  keys: TabVars.ids(),
                ),
                otherwise: noTab(),
              ),
            ),
          ],
          run: (c) async {
            final site = _siteIn(c);
            final source = _tab.of(c);
            final tab = site.tabs.where((t) => t.id == source).firstOrNull;
            if (tab == null || !site.tabPersistsNavState(tab)) return null;
            if (_page.from(c).isLoaded(site.siteId)) {
              return switch (await site.captureNavigationState()) {
                (:final tab, :final bytes) when tab == source => bytes,
                _ => null,
              };
            }
            return c.api.loadState(site.stateKeyForTab(source));
          },
          reply: Expr.choose(
            when: _dupView.value,
            then: _label.value,
            otherwise: TabVars.savedFor(
              _site.value,
              tab: _tab.value,
              keys: TabVars.ids(),
            ),
          ),
        ),
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.skip,
            when: _label.value.eq(_noBytes),
            then: [],
            next: to(TabPlace.tDupInsert),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.save,
          then: [],
          next: to(TabPlace.tDupSave),
        ),
      ),
      // The copy's file written: the source's own history becomes the
      // copy's own.
      TabPlace.tDupSave => Step(
        ActivationStep.dupSaveReply,
        holds: null,
        call: Call.on(
          _files,
          run: (c) => c.api.saveState(_copyKey(c), state: _label.of(c)!),
          writes: [
            TabVars.copied(
              _site.value,
              copy: _copy.value,
              source: _tab.value,
              as: _copyAs.value.unwrapped,
              label: _labelTla,
            ),
          ],
        ),
        site: _site.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [_wrote.becomes(_yes)],
          next: to(TabPlace.tDupInsert),
        ),
      ),
      // The copy joins the list beside its source, or is dropped with its
      // file when the source left meanwhile.
      TabPlace.tDupInsert => Step(
        ActivationStep.dupInsert,
        holds: null,
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.gone,
            when: ~_sourceStays,
            then: [],
            next: Expr.choose(
              when: _wrote.value,
              then: to(TabPlace.tDupRemove),
              otherwise: to(TabPlace.done),
            ),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            Act.of([
              _tabs.except(_site.value, to: _withCopy),
              // The copy runs as its source did and follows its link.
              TabVars.hostFn<SiteId, TabFlow>().becomes(
                TabVars.hostFn<SiteId, TabFlow>().value.exceptAt(
                  _site.value,
                  at: _copy.value,
                  to: _copyAs.value.unwrapped,
                ),
              ),
              TabVars.linkFn<SiteId, TabFlow>().becomes(
                TabVars.linkFn<SiteId, TabFlow>().value.exceptAt(
                  _site.value,
                  at: _copy.value,
                  to: _link.at(_site.value).at(_tab.value),
                ),
              ),
              TabVars.openerFn<SiteId, TabFlow>().becomes(
                TabVars.openerFn<SiteId, TabFlow>().value.exceptAt(
                  _site.value,
                  at: _copy.value,
                  to: _opener.at(_site.value).at(_tab.value),
                ),
              ),
            ], then: (c) => _page.from(c).duplicated(c)),
          ],
          next: to(TabPlace.done),
        ),
      ),
      TabPlace.tDupRemove => Step(
        ActivationStep.dupRemoveReply,
        holds: null,
        call: Call.on(
          _files,
          run: (c) => c.api.removeState(_copyKey(c)),
          writes: [
            TabVars.removedAs(
              _site.value,
              tab: _copy.value,
              as: _copyAs.value.unwrapped,
            ),
          ],
        ),
        site: _site.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(TabPlace.done),
        ),
      ),
      // The flips, in the reroute's turn. The tab on screen moves the slot
      // to the other site: across a rule another site shares it leaves the
      // loaded sites and its activation for the new route starts here, the
      // arm's spawn (LIR-024); else its webview is built again as the other
      // site, as a tab switch's rebind builds it.
      TabPlace.rFlip => Step(
        ActivationStep.rerouteFlip,
        holds: null,
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.unload,
            when:
                _slotFlips &
                movesRule.call([_runsAs(_site.value), _flippedAs(_site.value)]),
            then: [
              _beforeReroute,
              Act.of([
                _flip(_site.value),
                _loaded.becomes(_loaded.value.less(_site.value.asSet)),
                ...TabVars.rebound(
                  _site.value,
                  keys: TabVars.ids(),
                  tab: _active.at(_site.value),
                  label: noTab<TabFlow>(),
                  loaded: _loaded.value.less(_site.value.asSet),
                  warmth: const DropsWarm(),
                ),
              ], then: (c) => _page.from(c).reroute(c)),
              Spawn(
                ActivationStep.tap,
                site: _site.value,
                when: _reopened,
                start: (c) => _page.from(c).activate(_site.of(c)),
              ),
            ],
            next: to(TabPlace.rRemove),
          ),
          Branch(
            StepOutcome.rebind,
            when: _slotFlips,
            then: [
              _beforeReroute,
              Act.of([
                _flip(_site.value),
                ...TabVars.rebound(
                  _site.value,
                  keys: TabVars.ids(),
                  tab: _active.at(_site.value),
                  label: noTab<TabFlow>(),
                  loaded: _loaded.value,
                  warmth: const DropsWarm(),
                ),
              ], then: (c) => _page.from(c).reroute(c)),
            ],
            next: to(TabPlace.rRemove),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            _beforeReroute,
            Act.of([
              _flip(_site.value),
              TabVars.warmGone(
                _site.value,
                keys: TabVars.ids(),
                tabs: _misplaced(_site.value, routed: _routed.value),
              ),
            ], then: (c) => _page.from(c).reroute(c)),
          ],
          next: to(TabPlace.rRemove),
        ),
      ),
      // A flipped tab's file under the site it left removed, one a step.
      TabPlace.rRemove => Step(
        ActivationStep.rerouteRemoveReply,
        holds: null,
        pick: _eachClosing,
        call: Call.on(
          _files,
          run: (c) =>
              c.api.removeState(_flow.from(c).dropped[_eachClosing.it.run(c)]!),
          writes: [
            TabVars.removedAs(
              _site.value,
              tab: _eachClosing.it,
              as: _ranAs.value.at(_eachClosing.it),
            ),
          ],
        ),
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.more,
            when: ~_closing.value.without(_eachClosing.it).isEmpty,
            then: [_closing.becomes(_closing.value.without(_eachClosing.it))],
            next: to(TabPlace.rRemove),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.end,
          then: [],
          next: to(TabPlace.done),
        ),
      ),
      TabPlace.hLand => _landOn(ActivationStep.homeLand),
      TabPlace.oLand => _landOn(ActivationStep.ownerLand),
      TabPlace.cLand => _childLand(ActivationStep.childLand, opens: true),
      // The listed child's switch begins (tCap) in a step of its own, since
      // the capture reads at its start the hosts the insert wrote.
      TabPlace.cOpen => Step(
        ActivationStep.childOpen,
        holds: null,
        site: _site.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(TabPlace.tCap),
        ),
      ),
      TabPlace.pLand => _childLand(ActivationStep.parkLand, opens: false),
      // The reopened tab's landing: it runs as the site it ran as while
      // that is listed (LIR-032), fixed before its file is written under
      // that site's key, and takes a fresh id; with no history to write it
      // goes straight to its insert.
      TabPlace.reLand => Step(
        ActivationStep.reopenLand,
        holds: null,
        pick: _eachChildHost,
        site: _site.value,
        otherwise: Otherwise(
          StepOutcome.go,
          pick: _eachKept,
          then: [
            _mintedBumpSite,
            _copy.becomes(_mintSite),
            _copyAs.becomes(_eachChildHost.it),
          ],
          next: Expr.choose(
            when: _eachKept.it,
            then: to(TabPlace.reSave),
            otherwise: to(TabPlace.reInsert),
          ),
        ),
      ),
      // The history a close kept written back: the closed tab's own,
      // under the key of the site the reopened tab runs as.
      TabPlace.reSave => Step(
        ActivationStep.reopenSaveReply,
        holds: null,
        call: Call.on(
          _files,
          run: (c) => c.api.saveState(
            _copyKey(c),
            state: _flow.from(c).reopening!.history!,
          ),
          writes: [
            TabVars.file<SiteId, TabFlow>().becomes(
              TabVars.file<SiteId, TabFlow>().value.exceptAt(
                _site.value,
                at: _copy.value,
                by: _copyAs.value.unwrapped,
                to: _copy.value,
              ),
            ),
          ],
        ),
        site: _site.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(TabPlace.reInsert),
        ),
      ),
      // The reopened tab joins its site's list where it stood, running as
      // its landing fixed and following no opener: a tab nothing routes.
      TabPlace.reInsert => Step(
        ActivationStep.reopenInsert,
        holds: null,
        site: _site.value,
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            Act.of([
              _tabs.except(_site.value, to: _withReopened),
              TabVars.hostFn<SiteId, TabFlow>().becomes(
                TabVars.hostFn<SiteId, TabFlow>().value.exceptAt(
                  _site.value,
                  at: _copy.value,
                  to: _copyAs.value.unwrapped,
                ),
              ),
              TabVars.linkFn<SiteId, TabFlow>().becomes(
                TabVars.linkFn<SiteId, TabFlow>().value.exceptAt(
                  _site.value,
                  at: _copy.value,
                  to: _noLink,
                ),
              ),
              TabVars.openerFn<SiteId, TabFlow>().becomes(
                TabVars.openerFn<SiteId, TabFlow>().value.exceptAt(
                  _site.value,
                  at: _copy.value,
                  to: _noLink,
                ),
              ),
            ], then: (c) => _page.from(c).reopened(c)),
          ],
          next: to(TabPlace.done),
        ),
      ),
    },
  );

  /// A child of the flow's site joins its list under its parent, running
  /// as the site [_eachChildHost] picks and following what [_eachChildLink]
  /// picks (LIR-032, LIR-034). One the handler [opens] is switched to as a
  /// new tab is (cOpen, then tCap); a parked one is offered (TAB-006).
  static Step<TabFlow, TabPlace> _childLand(
    ActivationStep step, {
    required bool opens,
  }) => Step(
    step,
    holds: null,
    pick: _eachChildHost,
    site: _site.value,
    otherwise: Otherwise(
      StepOutcome.go,
      pick: _eachChildLink,
      then: [
        _mintedBumpSite,
        Act.of([
          _tabs.except(_site.value, to: _withChild),
          TabVars.hostFn<SiteId, TabFlow>().becomes(
            TabVars.hostFn<SiteId, TabFlow>().value.exceptAt(
              _site.value,
              at: _mintSite,
              to: _eachChildHost.it,
            ),
          ),
          TabVars.linkFn<SiteId, TabFlow>().becomes(
            TabVars.linkFn<SiteId, TabFlow>().value.exceptAt(
              _site.value,
              at: _mintSite,
              to: _eachChildLink.it,
            ),
          ),
          // A child follows the opener its handler named at its input.
          TabVars.openerFn<SiteId, TabFlow>().becomes(
            TabVars.openerFn<SiteId, TabFlow>().value.exceptAt(
              _site.value,
              at: _mintSite,
              to: _copyAs.value,
            ),
          ),
        ], then: opens ? null : (c) => _page.from(c).parked(c)),
        if (opens) ...[_tab.becomes(_mintSite), _keep.becomes(_yes)],
      ],
      next: to(opens ? TabPlace.cOpen : TabPlace.done),
    ),
  );

  /// The tab a landing or an owner-run move names, decided by the engine:
  /// the one the site is on stays; a loaded site lists it and switches to
  /// it as New tab does (tCap); one with no webview takes it as the list
  /// and the pointer at once, so its next build is of that tab. Each move
  /// marks its own [step].
  static Step<TabFlow, TabPlace> _landOn(ActivationStep step) => Step(
    step,
    holds: null,
    pick: _eachLanding,
    site: _site.value,
    tab: _landing,
    branches: [
      Branch(
        StepOutcome.stay,
        when: _landing.eq(_active.at(_site.value)),
        then: [],
        next: to(TabPlace.done),
      ),
      Branch(
        StepOutcome.rebind,
        when: _loaded.value.has(_site.value),
        then: [
          _landedMint,
          Act.of([_tabs.except(_site.value, to: _landedTabs)]),
          _tab.becomes(_landing),
          _keep.becomes(_yes),
        ],
        next: to(TabPlace.tCap),
      ),
    ],
    otherwise: Otherwise(
      StepOutcome.go,
      then: [
        _landedMint,
        Act.of([
          _tabs.except(_site.value, to: _landedTabs),
          _active.except(_site.value, to: _landing),
        ], then: (c) => _page.from(c).landed(c)),
      ],
      next: to(TabPlace.done),
    ),
  );
}
