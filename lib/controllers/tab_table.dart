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

  /// What the tab steps ask of the page and do to it ([TabCalls]): the
  /// rebinds that finish a switch change the webview's binding and what
  /// is queued for it.
  static final _page = Port<TabCalls, TabFlow>(
    'page',
    reads: const {},
    changes: {ModelVar.built, ModelVar.hist, ModelVar.queued},
    of: (w) => TabCalls(w._c),
  );

  /// What a child tab not listed yet follows, read as [_link] reads a
  /// listed one's (`link`, LIR-034).
  static final _childLinks = Port<ChildLinks, TabFlow>(
    'childLinks',
    reads: {ModelVar.link, ModelVar.host},
    changes: const {},
    of: (w) => ChildLinks(w._c),
  );

  /// The tabs' state files, the model's `file` (TAB-003).
  static final _files = Port<WebViewStateStorage, TabFlow>(
    'files',
    reads: {ModelVar.file},
    changes: {ModelVar.file},
    of: (w) => w._c.navStates,
  );

  static Expr<WebViewModel, TabFlow> get _current => Expr.op(
        HandPaired.tabSiteOnScreen,
        tla: 'current',
        run: (c) => _flow.from(c).site,
        reads: const Reads(vars: {ModelVar.current}),
      );
  static final _currentVar = Var<WebViewModel?, TabFlow>(
    ModelVar.current,
    read: (w) => w._c._sites.shown,
  );
  static final _marker = Var<ActivationMarker<WebViewModel>?, TabFlow>(
    ModelVar.marker,
    read: (w) => w._c._sites.activating,
  );

  /// The flow's site is on screen, or the target of the activation in
  /// flight: where a slot that runs as another site opens again.
  static final _reopened = _reopenedAt(_site.value);
  static Expr<bool, TabFlow> _reopenedAt(Expr<WebViewModel, TabFlow> s) =>
      _currentVar.value.eq(s) |
      _marker.value.part('t', get: (m) => m?.target).eq(s);
  static final _loaded = Mutable<Iterable<WebViewModel>, TabFlow>.over(
    ModelVar.loaded,
    of: (w) => w._c._sites.vars.loaded,
  );
  static final _active = TabVars.active<TabFlow>();
  static final _tier = tierOf<TabFlow>();

  /// `tabs[s]` as this controller writes it: the engine's list, whose ids
  /// are the model's set.
  static final _tabs = Indexed<WebViewModel, List<SiteTab>, TabFlow>.over(
    ModelVar.tabs,
    cell: WebViewModel.tabsCell,
  );
  static Expr<List<TabId>, TabFlow> _tabIds(Expr<WebViewModel, TabFlow> s) =>
      TabVars.tabs<TabFlow>().at(s);

  static const _kind = Field<FlowKind, TabFlow>(FlowField.kind);
  static const _site = Field<WebViewModel, TabFlow>(FlowField.site);
  static const _tab = Field<TabId, TabFlow>(FlowField.tab);
  static const _keep = Field<bool, TabFlow>(FlowField.keep);
  static const _rest = Field<List<SiteTab>, TabFlow>(FlowField.rest);
  static const _closing = Field<List<TabId>, TabFlow>(FlowField.closing);
  static const _copy = Field<TabId, TabFlow>(FlowField.copy);
  static const _copyAs = Field<WebViewModel, TabFlow>(FlowField.copyAs);
  static const _label = Field<Uint8List?, TabFlow>(FlowField.label);
  static const _wrote = Field<bool, TabFlow>(FlowField.wrote);

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
    run: (c) => _page.from(c).isShown(_flow.from(c).site),
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
    run: (_) => true, reads: const Reads(vars: {ModelVar.current},
    base: {BaseOp.hasFresh}),
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
    reads: const Reads(vars: {ModelVar.current, ModelVar.minted}, base: {BaseOp.mint}),
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
  static final _resultTabs = Expr.handPaired<List<SiteTab>, TabFlow>(
    HandPaired.tabsAfterClose,
    tla: 'tabs[current] \\ {s}',
    run: (c) => _flow.from(c).result!.tabs,
    reads: const Reads(vars: {ModelVar.current, ModelVar.tabs}),
  );
  static final _closedIds = Expr.handPaired<List<TabId>, TabFlow>(
    HandPaired.closedTabIds,
    tla: '{s}',
    run: (c) => _flow.from(c).result!.closedIds,
    reads: Reads.none,
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

  static final _live = _currentVar.value.eq(_site.value) | _loaded.value.has(_site.value);

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
  /// slot does under one process-wide proxy, where the slot leaves the
  /// loaded sites. Only under containers does a tab run as another site
  /// ([mayHost]).
  static final _identityChanges =
      _containers &
      _globalProxy &
      _tabHost.at(_site.value).at(_tab.value).neq(_runsAs(_site.value));

  static final _containers = Constant<bool, TabFlow>(
    ModelConst.containers,
    read: (w) => w._c._sites.useContainers,
  ).value;
  static final _sitesListed = Constant<List<WebViewModel>, TabFlow>(
    ModelConst.sites,
    read: (w) => w._c._sites.models,
  ).value;
  static final _noLink = Expr.constant<WebViewModel?, TabFlow>(null, tla: '0');

  /// The listed tabs of [s] a link opened into another site's domain,
  /// which s's switch moves between the two (LIR-034).
  static Expr<List<TabId>, TabFlow> _relinked(Expr<WebViewModel, TabFlow> s) {
    const l = Bound<TabId, TabFlow>('l');
    final to = _link.at(s).at(l.it);
    return _tabIds(s).where(l, holds: ~(to.eq(_noLink) | to.eq(s)));
  }

  /// The site whose switch flipped: one whose tabs the model follows
  /// (`Tabbed`) with such a tab.
  static final _eachRerouted = () {
    const o = Bound<WebViewModel, TabFlow>('o');
    // Not `s`: the activation its slot's arm spawns binds that.
    return Pick<WebViewModel, TabFlow>(
      _sitesListed.where(
        o,
        holds: TabVars.tabbed<TabFlow>().has(o.it) & _relinked(o.it).isNotEmpty,
      ),
      first: (c, {required among}) => _flow.from(c).site,
      name: 'r',
    );
  }();
  static final _rerouted = _eachRerouted.it;

  /// The sites with tabs a reset lands at home (TAB-014).
  static final _eachLanded = Pick<WebViewModel, TabFlow>(
    Expr.op(
      HandPaired.landedSites,
      tla: r'Listed \cap Resettable \cap Tabbed',
      run: (c) => [_flow.from(c).site],
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
  static final _eachOwnerRun = Pick<WebViewModel, TabFlow>(
    Expr.op(
      HandPaired.ownerRunSites,
      tla: r'Listed \cap Tabbed',
      run: (c) => [_flow.from(c).site],
      reads: const Reads(base: {BaseOp.listed}),
      needs: const {(of: ModelConst.tabbed, set: true)},
    ),
  );
  static final _ownerRunning = _eachOwnerRun.it;

  /// The site with tabs a child tab opens in, while the model's pool has
  /// a fresh tab id for it.
  static final _eachChildOwner = Pick<WebViewModel, TabFlow>(
    Expr.op(
      HandPaired.childSites,
      tla: r'{o \in Listed \cap Tabbed : HasFresh(o)}',
      run: (c) => [_flow.from(c).site],
      reads: const Reads(base: {BaseOp.listed, BaseOp.hasFresh}),
      needs: const {(of: ModelConst.tabbed, set: true)},
    ),
  );
  static final _childOwner = _eachChildOwner.it;

  /// The site a child tab runs as: another listed site where containers
  /// keep their cookies apart (LIR-032), else its own.
  static final _eachChildHost = Pick<WebViewModel, TabFlow>(
    Expr.op(
      HandPaired.childHosts,
      tla: r'IF Containers THEN Listed ELSE {fl[f].site}',
      run: (c) => [_page.from(c).childHost(_flow.from(c).fresh!, owner: _site.of(c))],
      reads: const Reads(base: {BaseOp.listed}),
    ),
    name: 'hs',
  );

  /// What a child tab follows while its opener routes outbound links
  /// (LIR-034): a listed site, or none (`0`) for one no link opened.
  static final _eachChildLink = Pick<WebViewModel?, TabFlow>(
    Expr.op(
      HandPaired.childLinks,
      tla: r'{0} \cup Listed',
      run: (c) => [_childLinks.from(c).of(_flow.from(c).fresh!, owner: _site.of(c))],
      reads: const Reads(vars: {ModelVar.link, ModelVar.host}, base: {BaseOp.listed}),
    ),
    name: 'lk',
  );
  static final _withChild = Expr.checked(
    rule: _tabIds(_site.value).union(_mintSite.asSet),
    run: (c) => TabLifecycleEngine.insertChild(_site.of(c).tabs, tab: _flow.from(c).fresh!),
    key: (SiteTab t) => t.id,
    why: "a child tab joins its site's list",
  );

  /// The tab a landing names: the one the site is on, a parked one, or a
  /// fresh one while the pool has one; the engine decides which.
  static final _eachLanding = Pick<TabId, TabFlow>(
    Expr.op(
      HandPaired.landingTabs,
      tla: r'tabs[fl[f].site] \cup '
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

  /// Each of [s]'s relinked tabs runs as the other of its two sites.
  static Write<TabFlow> _flip(Expr<WebViewModel, TabFlow> s) {
    const t = Bound<TabId, TabFlow>('t');
    final host = TabVars.hostFn<TabFlow>();
    return host.becomes(
      host.value.except(
        s,
        to: host.value.at(s).exceptEach(
          _relinked(s),
          x: t,
          to: Expr.choose(
            when: host.value.at(s).at(t.it).eq(s),
            then: _link.at(s).at(t.it).unwrapped,
            otherwise: s,
          ),
        ),
      ),
    );
  }

  /// The site [tab] of [s] ran as before a reroute flipped it, whose key
  /// its old file is under.
  static Expr<WebViewModel, TabFlow> _left(
    Expr<WebViewModel, TabFlow> s, {
    required Expr<TabId, TabFlow> tab,
  }) => Expr.choose(
    when: _tabHost.at(s).at(tab).eq(s),
    then: _link.at(s).at(tab).unwrapped,
    otherwise: s,
  );

  /// The loaded sites as a reroute's flips found them.
  static final _beforeReroute = Note<TabFlow>(
    (c) => _flow.from(c).loadedBefore = _page.from(c).loaded,
  );

  /// The tab on screen is one the reroute flips: the slot runs as another
  /// site.
  static final _slotFlips = _relinked(_site.value).has(_active.at(_site.value));

  static final _globalProxy = Constant<bool, TabFlow>(
    ModelConst.globalProxy,
    read: (w) => TabCalls(w._c).processGlobal,
  ).value;
  static final _tabHost = TabVars.host<TabFlow>();
  static Expr<WebViewModel, TabFlow> _runsAs(Expr<WebViewModel, TabFlow> s) =>
      TabVars.runsAs<TabFlow>().call([s]);

  /// `link[s]` as the code reads it: the site each link tab runs as while
  /// its opener routes outbound links ([linkHosts]).
  static final _link = Indexed<WebViewModel, Map<TabId, WebViewModel?>, TabFlow>.reported(
    ModelVar.link,
    read: (w, {required at}) => w._c.linkHosts(at),
  );

  static String _copyKey(StepView<TabFlow> c) {
    final copy = _flow.from(c).fresh!;
    return webViewStateKey(copy.hostSiteId ?? _site.of(c).siteId, tabId: copy.id);
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
      // that takes over; the closed tab's file goes first (tRemove).
      TabPlace.closeTab => Step.input(
        ActivationStep.closeTab,
        enabled: _tabbedCurrent & (~_survivors.isEmpty | _hasFresh),
        pick: _eachTab,
        site: _current,
        tab: _chosenTab,
        branches: [_dropped],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            Note((c) {
              final f = _flow.from(c);
              f.result = f.subtree
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
            }),
            ..._starts,
            _tab.becomes(_chosenTab),
            _keep.becomes(_no),
            _rest.becomes(_resultTabs),
            _closing.becomes(_closedIds),
          ],
          next: to(TabPlace.tRemove),
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
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_rerouted),
            _closing.becomes(_relinked(_rerouted)),
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
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_childOwner),
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
          then: [
            _kind.becomes(Expr.constant(FlowKind.tab)),
            _site.becomes(_childOwner),
          ],
          next: to(TabPlace.pLand),
        ),
      ),
      TabPlace.tCap ||
      TabPlace.tCapSave ||
      TabPlace.tNav ||
      TabPlace.tRebind ||
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
      TabPlace.done => const Leaves(),
    },
  );

  /// The outgoing tab's back stack captured under the webview's tab, in
  /// the capture's two steps; a target tab that left the list meanwhile
  /// ends the switch first.
  static final _capture = captureSteps<WebViewModel, TabFlow, TabPlace>(
    names: (read: ActivationStep.tabCaptureReply, save: ActivationStep.tabCaptureSave),
    places: (save: TabPlace.tCapSave, after: to(TabPlace.tNav)),
    of: (
      site: _site.value,
      built: (s) => s.tabBinding.built,
      hosts: (s) => s.tabHosts,
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
            final site = _site.of(c);
            final incoming = _targetOf(c);
            if (incoming == null || !site.tabPersistsNavState(incoming)) {
              return null;
            }
            return c.api.loadState(
              webViewStateKey(incoming.hostSiteId ?? site.siteId, tabId: incoming.id),
            );
          },
          reply: TabVars.savedFor(_site.value, tab: _tab.value),
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
        otherwise: Otherwise(StepOutcome.go, then: [], next: to(TabPlace.tRebind)),
      ),
      // List, pointer and webview move in one turn: the bytes read are
      // queued for the target, the old webview goes, the rebuild frame
      // builds one for the target from them (TAB-003). A target that runs
      // as another site under one process-wide proxy takes the slot out of
      // the loaded sites in the same turn, and the site's activation for its
      // new route starts in that turn too, the arm's spawn (LIR-024).
      TabPlace.tRebind => Step(
        ActivationStep.tabRebind,
        holds: null,
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.unload,
            when: _identityChanges,
            then: [
              Act.of([
                _active.except(_site.value, to: _tab.value),
                _tabs.except(_site.value, to: _installed),
                ...TabVars.dropped(_site.value, kept: _targetIn),
                _loaded.becomes(_loaded.value.less(_site.value.asSet)),
                ...TabVars.rebound(
                  _site.value,
                  tab: _tab.value,
                  label: _labelTla,
                  loaded: _loaded.value.less(_site.value.asSet),
                ),
              ], then: (c) => _page.from(c).rebindAs(c)),
              Spawn(
                ActivationStep.tap,
                site: _site.value,
                when: _reopened,
                start: (c) => _page.from(c).activate(_site.of(c)),
              ),
            ],
            next: to(TabPlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of([
              _active.except(_site.value, to: _tab.value),
              _tabs.except(_site.value, to: _installed),
              ...TabVars.dropped(_site.value, kept: _targetIn),
              _tier.except(_site.value, to: _residentIfLoaded),
              ...TabVars.rebound(
                _site.value,
                tab: _tab.value,
                label: _labelTla,
                loaded: _loaded.value,
              ),
            ], then: (c) => _page.from(c).rebind(c)),
          ],
          next: to(TabPlace.done),
        ),
      ),
      // A closed tab's file removed; the last removal decides: the site
      // left with no tab lands on a fresh one at home, a closed active tab
      // hands the webview to the engine's next, a parked one just goes.
      TabPlace.tRemove => Step(
        ActivationStep.tabRemoveReply,
        holds: null,
        pick: _eachClosing,
        call: Call.on(
          _files,
          run: (c) => c.api.removeState(
            _site.of(c).stateKeyForTab(_eachClosing.it.run(c)),
          ),
          writes: [TabVars.removed(_site.value, tab: _eachClosing.it)],
        ),
        site: _site.value,
        branches: [
          Branch(
            StepOutcome.more,
            when: ~_closing.value.without(_eachClosing.it).isEmpty,
            then: [_closing.becomes(_closing.value.without(_eachClosing.it))],
            next: to(TabPlace.tRemove),
          ),
          Branch(
            StepOutcome.rebind,
            when: _restIds.isEmpty,
            then: [
              Note((c) => _flow.from(c).fresh = SiteTab(url: _site.of(c).initUrl)),
              _mintedBumpSite,
              _tab.becomes(_mintSite),
              _rest.becomes(_onlyFresh),
            ],
            next: to(TabPlace.tNav),
          ),
          Branch(
            StepOutcome.rebind,
            when: _tab.value.eq(_active.at(_site.value)) & _live,
            pick: _nextSurvivor,
            tab: _nextSurvivor.it,
            then: [_tab.becomes(_nextSurvivor.it)],
            next: to(TabPlace.tNav),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.end,
          pick: _nextSurvivor,
          tab: _nextSurvivor.it,
          then: [
            Act.of([
              _tabs.except(_site.value, to: _rest.value),
              ...TabVars.dropped(_site.value, kept: _restIds),
              _active.except(
                _site.value,
                to: Expr.choose(
                  when: _tab.value.eq(_active.at(_site.value)),
                  then: _nextSurvivor.it,
                  otherwise: _active.at(_site.value),
                ),
              ),
            ], then: (c) => _page.from(c).closed(c)),
          ],
          next: to(TabPlace.done),
        ),
      ),
      // The duplicate's source read: the webview's back stack when the
      // site is loaded and the webview is the source's, else its file.
      TabPlace.tDupRead => Step(
        ActivationStep.dupReadReply,
        holds: null,
        call: _label.receivesOn(
          _files,
          run: (c) async {
            final site = _site.of(c);
            final source = _tab.of(c);
            final tab = site.tabs.where((t) => t.id == source).firstOrNull;
            if (tab == null || !site.tabPersistsNavState(tab)) return null;
            if (_page.from(c).isLoaded(site)) {
              return switch (await site.captureNavigationState()) {
                (:final tab, :final bytes) when tab == source => bytes,
                _ => null,
              };
            }
            return c.api.loadState(site.stateKeyForTab(source));
          },
          reply: TabVars.dupSource(
            _site.value,
            source: _tab.value,
            loaded: _loaded.value,
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
        otherwise: Otherwise(StepOutcome.save, then: [], next: to(TabPlace.tDupSave)),
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
              as: _copyAs.value,
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
            Act.of(
              [
                _tabs.except(_site.value, to: _withCopy),
                // The copy runs as its source did and follows its link.
                TabVars.hostFn<TabFlow>().becomes(
                  TabVars.hostFn<TabFlow>().value.exceptAt(
                    _site.value,
                    at: _copy.value,
                    to: _copyAs.value,
                  ),
                ),
                TabVars.linkFn<TabFlow>().becomes(
                  TabVars.linkFn<TabFlow>().value.exceptAt(
                    _site.value,
                    at: _copy.value,
                    to: _link.at(_site.value).at(_tab.value),
                  ),
                ),
              ],
              then: (c) => _page.from(c).duplicated(c),
            ),
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
            TabVars.removedAs(_site.value, tab: _copy.value, as: _copyAs.value),
          ],
        ),
        site: _site.value,
        otherwise: Otherwise(StepOutcome.none, then: [], next: to(TabPlace.done)),
      ),
      // The flips, in the reroute's turn. The tab on screen moves the slot
      // to the other site: under one process-wide proxy it leaves the
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
            when: _slotFlips & _globalProxy,
            then: [
              _beforeReroute,
              Act.of([
                _flip(_site.value),
                _loaded.becomes(_loaded.value.less(_site.value.asSet)),
                ...TabVars.rebound(
                  _site.value,
                  tab: _active.at(_site.value),
                  label: noTab<TabFlow>(),
                  loaded: _loaded.value.less(_site.value.asSet),
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
                  tab: _active.at(_site.value),
                  label: noTab<TabFlow>(),
                  loaded: _loaded.value,
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
            Act.of([_flip(_site.value)], then: (c) => _page.from(c).reroute(c)),
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
          run: (c) => c.api.removeState(
            _flow.from(c).dropped[_eachClosing.it.run(c)]!,
          ),
          writes: [
            TabVars.removedAs(
              _site.value,
              tab: _eachClosing.it,
              as: _left(_site.value, tab: _eachClosing.it),
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
        otherwise: Otherwise(StepOutcome.end, then: [], next: to(TabPlace.done)),
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
        otherwise: Otherwise(StepOutcome.none, then: [], next: to(TabPlace.tCap)),
      ),
      TabPlace.pLand => _childLand(ActivationStep.parkLand, opens: false),
    },
  );

  /// A child of the flow's site joins its list under its parent, running
  /// as the site [_eachChildHost] picks and following what [_eachChildLink]
  /// picks (LIR-032, LIR-034). One the handler [opens] is switched to as a
  /// new tab is (cOpen, then tCap); a parked one is offered (TAB-006).
  static Step<TabFlow, TabPlace> _childLand(ActivationStep step, {required bool opens}) => Step(
    step,
    holds: null,
    pick: _eachChildHost,
    site: _site.value,
    otherwise: Otherwise(
      StepOutcome.go,
      pick: _eachChildLink,
      then: [
        _mintedBumpSite,
        Act.of(
          [
            _tabs.except(_site.value, to: _withChild),
            TabVars.hostFn<TabFlow>().becomes(
              TabVars.hostFn<TabFlow>().value.exceptAt(
                _site.value,
                at: _mintSite,
                to: _eachChildHost.it,
              ),
            ),
            TabVars.linkFn<TabFlow>().becomes(
              TabVars.linkFn<TabFlow>().value.exceptAt(
                _site.value,
                at: _mintSite,
                to: _eachChildLink.it,
              ),
            ),
          ],
          then: opens ? null : (c) => _page.from(c).parked(c),
        ),
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
