import 'dart:async';
import 'dart:typed_data';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/runtime_vars.dart' show ActivationMarker;
import 'package:webspace/controllers/tab_vars.dart';
import 'package:webspace/services/cookie_isolation.dart' show tierOf;
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tab_handling_gate.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/services/tab_return_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart'
    show TabsSheetListing, TabsSheetSite;

part 'tab_flow.dart';
part 'tab_table.dart';

/// What the tab flows ask of the page.
abstract interface class TabsHost implements PageHost {
  /// A capture of [model]'s back stack under its webview's tab; null when
  /// that tab keeps none.
  NavCapture? beginNavCapture(WebViewModel model);

  /// Drops a debounced capture queued for [siteId]: the webview it would
  /// read is about to go.
  void cancelPendingCapture(SiteId siteId);

  void enterFullscreen();

  Future<void> activate(WebViewModel site);

  Future<void> saveCurrentIndex();

  Future<void> saveSelectedWebspace();

  /// WEBSPACE-012: switches to "All" when the selected webspace hides
  /// [model].
  Future<void> revealSite(WebViewModel model);

  /// Tells the user a tab opened in the background, with a way to it.
  void offerOpenTab(WebViewModel model, {required TabId tabId});

  /// The sites that can run a link of [opener]'s as a tab in [owner]'s tree
  /// (LIR-032).
  List<DispatchableSite> tabHostsIn(WebViewModel owner,
      {required WebViewModel opener});

  /// [model] left the loaded set outside the unload funnel, for [why].
  void noteUnloaded(WebViewModel model, {required String why});
}

/// A site's tabs (TAB-002..TAB-019): one container and one webview per site,
/// shared by its tabs. The active tab is the one bound to the webview; every
/// other tab is a record plus, when it has a back stack worth keeping, one
/// encrypted state file. So a tab switch is the savedForRestore walk applied
/// per tab (capture, dispose, queue, rebuild) and the number of live webviews
/// never moves.
class TabsController {
  TabsController(
    this._sites, {
    required TabsHost host,
    required this.navStates,
    required this.residency,
  }) : _host = host;

  final SiteRuntime _sites;
  final TabsHost _host;
  final WebViewStateStorage navStates;
  final ResidencyHost residency;

  /// Re-entrancy guard for the tab handlers. Each of them awaits a capture and
  /// a disk read before it mutates `tabs`; a second tap arriving in that window
  /// would capture the outgoing tab's stack twice and bind the wrong one. Work
  /// that arrives while it is held and must not be dropped (LIR-034's
  /// reconcile) waits on the gate and runs when it is released.
  late final TabHandlingGate _gate = TabHandlingGate(scheduleMicrotask);

  /// Jumps the Tabs sheet made between sites' slots, the way Back takes
  /// (TAB-019). Any other way to another site drops it.
  List<TabReturn> _returns = const [];

  bool get busy => _gate.busy;

  /// [body] once no tab handler holds the gate, holding it meanwhile.
  Future<T> runWhenIdle<T>(Future<T> Function() body) =>
      _gate.runWhenIdle(body);

  /// Completes once no tab handler is running.
  Future<void> settled() async {
    while (_gate.busy) {
      await _gate.idle();
    }
  }

  /// Another site by any way leaves the Tabs sheet's way back behind
  /// (TAB-019); a jump the sheet makes puts its own back once it lands.
  void forgetReturns() => _returns = const [];

  TabReturn? wayBackFrom(WebViewModel model) =>
      TabReturnEngine.wayBack(_returns,
          siteId: model.siteId, activeTabId: model.activeTabId);

  /// Whether [site] has tabs (TAB-013). Off, every way into its tabs is
  /// closed and it shows its active tab alone.
  bool enabledFor(WebViewModel? site) =>
      site != null &&
      _sites.models.contains(site) &&
      site.effectiveTabsEnabled;

  /// [act] on the site on screen when called, or null where that site has no
  /// tabs, so a button bound to it offers nothing there.
  void Function()? forShownSite(Future<void> Function(WebViewModel site) act) =>
      enabledFor(_sites.shown)
          ? () {
              if (_sites.shown case final shown?) unawaited(act(shown));
            }
          : null;

  /// Every site with tabs: the current webspace's in the order the drawer
  /// shows them, then the rest, whose trees can hold tabs that run as a site
  /// the webspace shows (TAB-017). A site without tabs is left out, so its
  /// stored ones cannot be opened from another site's list.
  List<TabsSheetSite> sheetSites() => _sheetSitesOver(_sites.filteredIndices());

  /// [sheetSites] for the library's tab tree, where no site is on screen:
  /// the sites [scope] holds in its order, "All" holding every site.
  List<TabsSheetSite> sheetSitesIn(WebspaceId scope) => _sheetSitesOver(
        WebspaceSelectionEngine.filteredSiteIndices(
          selectedWebspaceId: scope,
          webspaces: _sites.webspaces,
          siteCount: _sites.models.length,
        ),
      );

  /// What the Tabs sheet lists: [sheetSites] and the way back from the site
  /// on screen, or with [scope] the library's tab tree, with no way back.
  TabsSheetListing sheetListing({WebspaceId? scope}) => switch ((scope, _sites.shown)) {
        (null, final shown?) => (sites: sheetSites(), wayBack: wayBackFrom(shown)),
        (null, null) => (sites: sheetSites(), wayBack: null),
        (final library?, _) => (sites: sheetSitesIn(library), wayBack: null),
      };

  /// [closeTab] asked from the Tabs sheet, which stays up for the next one,
  /// so a close tapped while another lands must not be dropped as busy: it
  /// waits for a free gate and asks in the turn it finds one, as an
  /// owner-run move does. Completes with what the sheet lists once the close
  /// has landed.
  Future<TabsSheetListing> closeFromSheet(WebViewModel model,
      {required TabId tabId, required bool subtree, WebspaceId? scope}) async {
    while (_gate.busy) {
      await _gate.idle();
    }
    if (_host.mounted && _sites.models.contains(model)) {
      assert(!_gate.busy, 'a close from the Tabs sheet asks on a free gate');
      await closeTab(model, tabId: tabId, subtree: subtree);
    }
    return sheetListing(scope: scope);
  }

  List<TabsSheetSite> _sheetSitesOver(List<int> view) {
    final shown = view.toSet();
    TabsSheetSite site(int i) => TabsSheetSite(
          model: _sites.models[i],
          isCurrent: i == _sites.current,
          isLoaded: _sites.isLoadedAt(i),
          inView: shown.contains(i),
        );
    return [
      for (final i in view)
        if (enabledFor(_sites.models[i])) site(i),
      for (var i = 0; i < _sites.models.length; i++)
        if (!shown.contains(i) && enabledFor(_sites.models[i])) site(i),
    ];
  }

  /// Whether [host] may run a tab in [owner]'s tree (LIR-019): the container
  /// engine, a host with a persistent container of its own, and neither side
  /// in an archive.
  bool mayHost(WebViewModel host, {required WebViewModel owner}) =>
      _sites.useContainers &&
      !identical(host, owner) &&
      !host.effectiveIncognito &&
      !host.isArchiveTier &&
      !owner.isArchiveTier;

  /// Land a site with tabs on a tab at its home page (TAB-014): the one it is
  /// on when that is home, else a parked tab at home, else a new one. The tab
  /// it leaves parks with its back stack, as for New tab. It is the
  /// [TabTable.tabInputs] landing, and the tab it names [TabTable.tabFlow]'s
  /// first step.
  Future<void> landOnHomeTab(WebViewModel model) async {
    final landing = TabLifecycleEngine.homeLanding(
        model.tabs, activeTabId: model.activeTabId, initUrl: model.initUrl);
    final c = StepContext(TabFlow(
      this,
      site: model,
      requested: landing?.activeTabId ?? model.activeTabId,
      landed: landing?.tabs ?? model.tabs,
    ));
    final next = TabTable.tabInputs.runInput(c, from: TabPlace.homeLanding);
    if (next == TabPlace.done) {
      LogTag.tabs.debug(
          'Home landing for "${model.name}" skipped: a tab change is running',
          sensitive: true);
      return;
    }
    await _gate.hold(() => _runTabFlow(c, from: next));
  }

  /// Move [model]'s webview from whatever tab it is on to [targetTabId]:
  /// [TabTable.tabFlow] from its capture, or from its nav read when the tab
  /// being left is being closed ([captureOutgoing] false: its stack is going
  /// away with it). [tabs] replaces the list in the same turn as the active id.
  Future<void> switchActiveTab(
    WebViewModel model, {
    required TabId targetTabId,
    List<SiteTab>? tabs,
    bool captureOutgoing = true,
  }) async {
    if (!(tabs ?? model.tabs).any((t) => t.id == targetTabId)) return;
    final c = StepContext(TabFlow(this, site: model));
    TabTable._kind.put(c, value: FlowKind.tab);
    TabTable._site.put(c, value: model);
    TabTable._tab.put(c, value: targetTabId);
    TabTable._keep.put(c, value: captureOutgoing);
    if (tabs != null) TabTable._rest.put(c, value: tabs);
    await _runTabFlow(c, from: captureOutgoing ? TabPlace.tCap : TabPlace.tNav);
  }

  /// Runs [TabTable.tabFlow] from [from] and what follows its end: the shell
  /// and the save a rebind owes, the offer a duplicate makes.
  Future<void> _runTabFlow(StepContext<TabFlow> c, {required TabPlace from}) async {
    await TabTable.tabFlow.run(c, from: from);
    final w = c.world;
    if (!_host.mounted) return;
    if (w.rebound) {
      final model = w.site;
      // Only the site on screen owns the shell. An offscreen switch (a
      // shortcut landing a sibling at home) must not take the app into
      // full screen.
      if (model.fullscreenMode && identical(model, _sites.shown)) {
        _host.enterFullscreen();
      }
      LogTag.tabs.debug(
          'Bound "${model.name}" to tab ${model.activeTabId} '
          '(${model.tabs.length} tabs)',
          sensitive: true);
    }
    if (w.commitAfter) await _host.commitSites(const SitesEdited());
    if (w.offer case final copy?) _host.offerOpenTab(w.site, tabId: copy);
  }

  /// LIR-034: every tab a link opened runs as its opener's routing switch says
  /// now. A tab that changes container loses its saved back stack, which is a
  /// transcript of the identity it leaves, and reloads its page in the new
  /// one: the tab on screen at once, a slot in the background when it is next
  /// shown. Runs after a site's settings close, at startup and after an
  /// import. While a tab change is running it waits for it (TabHandlingGate),
  /// since both rewrite tab lists across awaits.
  ///
  /// The flips one site's switch makes in its own tree are the
  /// [TabTable.tabInputs] reroute and its removals; any other set of flips
  /// (several sites' at once, as an import may, or tabs another site opened)
  /// runs as the same writes in a commit no step takes yet.
  Future<void> reconcileLinkTabs() async {
    if (_gate.busy) {
      _gate.deferUntilIdle(() {
        if (_host.mounted) unawaited(reconcileLinkTabs());
      });
      return;
    }
    // One synchronous pass over every tab list: nothing can interleave
    // between reading what a tab runs as and rewriting it.
    final forgot = _forgetGoneOpeners();
    final flips = _linkFlips();
    if (_oneSiteReroutes(flips) case final owner?) {
      final c = StepContext(TabFlow(this, site: owner)..flips = flips);
      final next = TabTable.tabInputs.runInput(c, from: TabPlace.reroute);
      if (next == TabPlace.done) return;
      await _gate.hold(() => _runTabFlow(c, from: next));
      return;
    }
    if (flips.isEmpty && !forgot) return;
    await _gate.run(() async {
      final dropped = _applyFlips(
        flips,
        commit: const Commit.unmodeled(Unmodeled.identityChange),
        retire: true,
        loadedBefore: {..._sites.loaded},
      );
      for (final key in dropped.values) {
        await navStates.removeState(key);
      }
      if (!_host.mounted) return;
      _host.rebuild();
      await _host.commitSites(const SitesEdited());
    });
  }

  /// The site [tab], a tab of [owner] a link of [opener]'s opened, runs as
  /// when [opener] routes outbound links or not ([routes], LIR-034).
  SiteId _linkRunsAs(
    WebViewModel owner, {
    required SiteTab tab,
    required WebViewModel opener,
    required bool routes,
  }) {
    final home = tab.homeUrl!;
    return LinkIntentDispatchEngine.linkTabRunsAs(
      homeUrl: Uri.parse(home),
      homeNavigationDomain: getNormalizedDomain(home),
      routeOutboundLinks: routes,
      containersActive: _sites.useContainers,
      opener: SiteRoute(opener),
      openerPrefs: opener.outboundPreferences,
      hosts: () => _host.tabHostsIn(owner, opener: opener),
      current: tab.hostSiteId ?? owner.siteId,
    );
  }

  /// The site each of [owner]'s tabs runs as while its opener routes
  /// outbound links, the model's `link[s]` (LIR-034): null for a tab no
  /// link opened or whose opener is gone, and for one the list does not
  /// hold.
  Map<TabId, WebViewModel?> linkHosts(WebViewModel owner) => {
    for (final tab in owner.tabs) tab.id: _linkOf(owner, tab: tab),
  };

  /// [linkHosts]' entry for [tab] of [owner]'s, listed or about to be.
  WebViewModel? _linkOf(WebViewModel owner, {required SiteTab tab}) =>
      switch (tab.followsOpener ? _sites.byId(tab.openerSiteId!) : null) {
        final opener? =>
          _sites.byId(_linkRunsAs(owner, tab: tab, opener: opener, routes: true)) ??
              owner,
        null => null,
      };

  /// A link tab whose opener is gone: nothing decides for it any more, so it
  /// keeps the container it has (LIR-023 closes it if that is gone).
  bool _forgetGoneOpeners() {
    var forgot = false;
    for (final owner in _sites.models) {
      for (final tab in owner.tabs) {
        if (!tab.followsOpener || _sites.byId(tab.openerSiteId!) != null) {
          continue;
        }
        SiteTab.openerCell.write(
          at: tab,
          to: null,
          commit: const Commit.unmodeled(Unmodeled.siteSet),
        );
        forgot = true;
      }
    }
    return forgot;
  }

  /// Each link tab whose host its opener's switch moves, with the host it
  /// takes (null for its owner).
  List<LinkFlip> _linkFlips() => [
    for (final owner in _sites.models)
      for (final tab in owner.tabs)
        if (tab.followsOpener)
          if (_sites.byId(tab.openerSiteId!) case final opener?)
            if (_linkRunsAs(
                  owner,
                  tab: tab,
                  opener: opener,
                  routes: opener.effectiveRouteOutboundLinks,
                ) case final runsAs
                when (runsAs == owner.siteId ? null : runsAs) != tab.hostSiteId)
              (
                owner: owner,
                tab: tab,
                opener: opener,
                host: runsAs == owner.siteId ? null : runsAs,
              ),
  ];

  /// The site whose switch [flips] are, when they are the model's reroute:
  /// one site's own link tabs, every one its switch moves.
  WebViewModel? _oneSiteReroutes(List<LinkFlip> flips) {
    if (flips.isEmpty) return null;
    final owner = flips.first.owner;
    if (flips.any((f) => !identical(f.owner, owner) || !identical(f.opener, owner))) {
      return null;
    }
    final links = linkHosts(owner);
    final flipping = {
      for (final t in owner.tabs)
        if (links[t.id] case final h? when !identical(h, owner)) t.id,
    };
    return flipping.length == flips.length &&
            flips.every((f) => flipping.contains(f.tab.id))
        ? owner
        : null;
  }

  /// [flips] written in [commit], each tab's old key returned for its file's
  /// removal. A slot that runs as another site from this turn lets its
  /// webview go in the same turn (LIR-024): a plan between the two would
  /// read the new identity's route for a webview on the old one. Across a
  /// rule another site shares ([TabCalls.movesRule]) the slot also leaves
  /// the loaded sites ([retire], where no step's write takes it out), so
  /// nothing builds it on its new route beside the sites it contends with,
  /// and it opens again.
  Map<TabId, String> _applyFlips(
    List<LinkFlip> flips, {
    required Commit commit,
    required bool retire,
    required Set<WebViewModel> loadedBefore,
  }) {
    final dropped = <TabId, String>{};
    final movedFrom = <WebViewModel, WebViewModel>{};
    for (final (:owner, :tab, :opener, :host) in flips) {
      final identityBefore = owner.runningIdentity;
      dropped[tab.id] = owner.stateKeyForTab(tab.id);
      LogTag.tabs.debug('Tab ${tab.id} of "${owner.name}" now runs as '
          '${host ?? owner.siteId} (opener ${opener.siteId})',
          sensitive: true);
      if (tab.id == owner.activeTabId) _host.cancelPendingCapture(owner.siteId);
      SiteTab.hostCell.write(at: tab, to: host, commit: commit);
      if (!identical(identityBefore, owner.runningIdentity)) {
        movedFrom.putIfAbsent(owner, () => identityBefore);
      }
    }
    for (final MapEntry(key: model, value: from) in movedFrom.entries) {
      final moves =
          TabCalls(this).movesRule(from: from, to: model.runningIdentity);
      if (moves && retire) _sites.retired(model, commit: commit);
      if (moves && loadedBefore.contains(model)) {
        _host.noteUnloaded(model, why: 'identity change');
      }
      model.disposeWebView(commit: commit);
      if (moves && retire) _reopen(model);
    }
    return dropped;
  }

  /// The model's reroute in its input's turn ([TabTable.tabInputs]): the flips
  /// its table decided, the loaded sites already left where it says so, the
  /// activation that opens the slot again its spawn.
  void _reroute(CommitView<TabFlow> c) {
    final flow = TabTable._flow.from(c);
    flow
      ..dropped = _applyFlips(
        flow.flips,
        commit: c.commit,
        retire: false,
        loadedBefore: flow.loadedBefore,
      )
      ..commitAfter = true;
    _host.rebuild();
  }

  /// [model] runs as another site from this turn. On screen, or opening for an
  /// activation planned for the identity it left ([TabTable._reopened]), it is
  /// activated again in the same turn, the input before any await: the new
  /// activation plans for the new route and supersedes the old, and no event
  /// sees the screen on a site neither loaded nor opening. A step's reroute
  /// does this as its [Spawn].
  void _reopen(WebViewModel model) {
    final c = StepContext(TabFlow(this, site: model));
    TabTable._site.put(c, value: model);
    if (TabTable._reopened.run(c)) unawaited(_host.activate(model));
  }

  /// Show [model]'s [tabId]. Used by the tab list, and by Back going back along
  /// the trail of jumps it made (TAB-019). On the site on screen it is the
  /// [TabTable.tabInputs] input; a site off screen is shown first.
  Future<void> openTab(WebViewModel model, {required TabId tabId}) async {
    if (!model.tabs.any((t) => t.id == tabId)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(TabFlow(this, site: model, requested: tabId));
      final next = TabTable.tabInputs.runInput(c, from: TabPlace.openTab);
      if (next == TabPlace.done) return;
      final trail = TabReturnEngine.afterOpen(
        _returns,
        fromSiteId: model.siteId,
        fromTabId: model.activeTabId,
        toSiteId: model.siteId,
        toTabId: tabId,
        webspaceId: _sites.selectedWebspaceId,
      );
      await _gate.hold(() => _runTabFlow(c, from: next));
      _returns = trail;
      return;
    }
    if (_gate.busy) {
      ActivationSteps.mark(ActivationStep.openTab,
          outcome: StepOutcome.busy, site: model);
      return;
    }
    await _gate.run(() async {
      if (!_sites.models.contains(model)) return;
      final from = _sites.shown;
      final back = from == null ? null : wayBackFrom(from);
      final trail = from == null
          ? const <TabReturn>[]
          : TabReturnEngine.afterOpen(
              _returns,
              fromSiteId: from.siteId,
              fromTabId: from.activeTabId,
              toSiteId: model.siteId,
              toTabId: tabId,
              webspaceId: _sites.selectedWebspaceId,
            );
      // The site is not on screen. When it has no webview either, moving the
      // pointer before activating means the activation builds the right tab
      // directly: no load of the tab the site happened to be on, and no
      // dispose right after it.
      final moves = model.activeTabId != tabId;
      final loaded = _sites.loaded.contains(model);
      commitInput(ActivationStep.openTab, outcome: StepOutcome.go, site: model,
          writes: (commit) {
        if (!moves || loaded) return;
        WebViewModel.activeTabCell.write(at: model, to: tabId, commit: commit);
        model.activeTab.lastActiveAt = DateTime.now();
        unawaited(_host.commitSites(const SitesEdited()));
      });
      if (moves && loaded) {
        await switchActiveTab(model, targetTabId: tabId);
        if (!_host.mounted) return;
      }
      // An "In {site}" row can belong to a site this webspace hides. Going
      // back puts back the webspace the jump left, if it shows the site.
      if (back != null && back.leadsBackTo(model.siteId, tabId: tabId)) {
        await _returnToWebspace(back.webspaceId, model: model);
      } else {
        await _host.revealSite(model);
      }
      if (!_host.mounted) return;
      await _host.activate(model);
      if (!_host.mounted) return;
      _returns = trail;
      _host.rebuild();
      await _host.saveCurrentIndex();
    });
  }

  /// TAB-019: the way back from a jump restores the webspace the jump left
  /// when that still shows [model]; otherwise WEBSPACE-012 decides.
  Future<void> _returnToWebspace(WebspaceId? webspaceId,
      {required WebViewModel model}) async {
    final ws = _sites.webspaces.where((w) => w.id == webspaceId).firstOrNull;
    if (ws == null ||
        webspaceId == _sites.selectedWebspaceId ||
        !(ws.isAll || ws.siteIndices.contains(_sites.models.indexOf(model)))) {
      await _host.revealSite(model);
      return;
    }
    _sites.selectedWebspaceId = webspaceId;
    _host.rebuild();
    await _host.saveSelectedWebspace();
  }

  /// S6: a link from a hosted tab back into [model]'s own domain opens as
  /// [model]'s child tab under it, running as [model], and takes the slot.
  Future<void> returnToOwner(WebViewModel model, {required String url}) =>
      openChildTab(model, url: url);

  /// LIR-018: before an owner URL loads into [model]'s slot, the slot moves to
  /// a tab [model] runs itself: the nearest such ancestor, or a new root tab.
  Future<void> bindOwnerRunTab(WebViewModel model) async {
    if (!model.runsHostedTab && !model.runsForeignTab) return;
    if (enabledFor(model)) {
      await _ownerRun(model);
      return;
    }
    if (!_sites.loaded.contains(model)) {
      model.bindOwnerRunTab();
      return;
    }
    await _gate.runWhenIdle(() async {
      var id = TabLifecycleEngine.ownerRunTab(model.tabs,
          activeTabId: model.activeTabId, isForeign: model.isForeignTab);
      if (id == null) {
        final tab = SiteTab(url: model.initUrl);
        WebViewModel.tabsCell.write(
            at: model,
            to: [...model.tabs, tab],
            commit: const Commit.unmodeled(Unmodeled.ownerRunTab));
        id = tab.id;
      }
      await switchActiveTab(model, targetTabId: id);
    });
  }

  /// [bindOwnerRunTab] for a site with tabs: the [TabTable.tabInputs] owner-run
  /// move, the tab the engine names [TabTable.tabFlow]'s landing (oLand), so a
  /// live slot's back stack is captured and its webview rebuilt as [model]. An
  /// owner URL may not load before it (LIR-034), so it waits for a free gate
  /// and asks in the turn it finds one: the gate is held past a tab flow's
  /// last step too (its commit, a [TabHandlingGate.runWhenIdle] waiter), so a
  /// move asked on a held gate could be dropped where the model sees no tab
  /// flow in flight.
  Future<void> _ownerRun(WebViewModel model) async {
    while (_gate.busy) {
      await _gate.idle();
    }
    if (!_host.mounted || !_sites.models.contains(model)) return;
    final move = TabLifecycleEngine.ownerRunMove(model.tabs,
        activeTabId: model.activeTabId,
        homeUrl: model.initUrl,
        isForeign: model.isForeignTab);
    final c = StepContext(TabFlow(
      this,
      site: model,
      requested: move?.active ?? model.activeTabId,
      landed: move?.tabs ?? model.tabs,
    ));
    final next = TabTable.tabInputs.runInput(c, from: TabPlace.ownerRun);
    await _gate.hold(() => _runTabFlow(c, from: next));
  }

  /// LIR-023: close every hosted tab whose host is gone or may no longer
  /// host, re-binding an owner whose active tab closed. Runs at startup and
  /// in the commit of an import, a delete, a site's settings change and a
  /// move across the archive boundary.
  Future<void> closeIneligibleHostedTabs() =>
      _gate.runWhenIdle(_closeIneligibleHostedTabsHeld);

  Future<void> _closeIneligibleHostedTabsHeld() async {
    // Sites, not rows: each close awaits, and a row can name another site
    // after an await.
    for (final model in [..._sites.models]) {
      if (!_sites.models.contains(model)) continue;
      if (!model.tabs.any((t) => t.hostSiteId != null)) continue;
      final result = TabLifecycleEngine.closeWhere(
        model.tabs,
        activeTabId: model.activeTabId,
        shouldClose: (t) {
          if (t.hostSiteId == null) return false;
          final host = model.hostOf(t);
          return host == null || !mayHost(host, owner: model);
        },
      );
      await _applyTabClose(model: model, result: result);
      if (!_host.mounted) return;
    }
  }

  /// Open a new tab at the site's home page, or at [url] for a search (TAB-005,
  /// LIR-030). The tab the user was on is kept: it parks, with its back stack
  /// captured. On the site on screen it is the [TabTable.tabInputs] input.
  Future<void> newTab(WebViewModel model, {String? url}) async {
    if (!enabledFor(model)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(TabFlow(this, site: model, url: url));
      final next = TabTable.tabInputs.runInput(c, from: TabPlace.newTab);
      if (next == TabPlace.done) return;
      await _gate.hold(() => _runTabFlow(c, from: next));
      return;
    }
    if (_gate.busy) {
      ActivationSteps.mark(ActivationStep.newTab,
          outcome: StepOutcome.busy, site: model);
      return;
    }
    await _gate.run(() async {
      if (!_sites.models.contains(model)) return;
      final tab = SiteTab(url: url ?? model.initUrl);
      // A site with a live webview has to go through the switch even when it
      // is offscreen: moving `activeTabId` on its own would leave that webview
      // showing the tab it was on while the model says otherwise, and the
      // outgoing tab's back stack would never be captured.
      final live = _sites.loaded.contains(model);
      commitInput(ActivationStep.newTab, outcome: StepOutcome.go, site: model,
          writes: (commit) {
        WebViewModel.tabsCell
            .write(at: model, to: [...model.tabs, tab], commit: commit);
        if (!live) {
          WebViewModel.activeTabCell.write(at: model, to: tab.id, commit: commit);
        }
      });
      if (!live) {
        await _host.activate(model);
        if (!_host.mounted) return;
        _host.rebuild();
        await _host.commitSites(const SitesEdited());
        return;
      }
      await switchActiveTab(model, targetTabId: tab.id);
      if (!_host.mounted) return;
      await _host.activate(model);
    });
  }

  /// A child tab of [owner]'s [parentTabId] (the active tab when it is gone
  /// or not given) at [url], running as [hostSiteId] or as [owner] itself,
  /// and switched to: a search's results (LIR-030), a link back to the owner
  /// (S6), a link into another of the user's sites (LIR-032). It is the
  /// [TabTable.tabInputs] child input, dropped while a tab handler runs, and
  /// the switch to it [TabTable.tabFlow]'s from the child's landing (cLand).
  Future<void> openChildTab(
    WebViewModel owner, {
    required String url,
    SiteId? hostSiteId,
    TabId? parentTabId,
    SiteId? openerSiteId,
    String? homeUrl,
  }) async {
    if (!owner.effectiveTabsEnabled) return;
    if (!_sites.models.contains(owner)) return;
    final parent = parentTabId != null &&
            owner.tabs.any((t) => t.id == parentTabId)
        ? parentTabId
        : owner.activeTabId;
    final tab = SiteTab(
      url: url,
      parentId: parent,
      hostSiteId: hostSiteId == owner.siteId ? null : hostSiteId,
      openerSiteId: openerSiteId,
      homeUrl: homeUrl,
    );
    final c = StepContext(TabFlow(this, site: owner)..fresh = tab);
    final next = TabTable.tabInputs.runInput(c, from: TabPlace.childTab);
    if (next == TabPlace.done) return;
    LogTag.tabs.debug('Opened a child tab of "${owner.name}"'
        '${tab.hostSiteId == null ? '' : ' run as ${tab.hostSiteId}'}',
        sensitive: true);
    await _gate.hold(() => _runTabFlow(c, from: next));
  }

  /// Copy the site's current tab, back stack included, into a new tab beside it
  /// (TAB-010). The copy opens parked, so the page on screen stays put and the
  /// copy costs a record plus a state file until it is first opened. On the
  /// site on screen it is the [TabTable.tabInputs] input; off screen the same
  /// flow from its read.
  Future<void> duplicateTab(WebViewModel model) async {
    if (!enabledFor(model)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(TabFlow(this, site: model));
      final next = TabTable.tabInputs.runInput(c, from: TabPlace.duplicateTab);
      if (next == TabPlace.done) return;
      await _gate.hold(() => _runTabFlow(c, from: next));
      return;
    }
    if (_gate.busy) {
      ActivationSteps.mark(ActivationStep.duplicateTab,
          outcome: StepOutcome.busy, site: model);
      return;
    }
    await _gate.run(() async {
      if (!_sites.models.contains(model)) return;
      final c = StepContext(TabFlow(this, site: model));
      c.world.fresh = _copyOf(model.activeTab);
      TabTable._kind.put(c, value: FlowKind.tab);
      TabTable._site.put(c, value: model);
      TabTable._tab.put(c, value: model.activeTabId);
      TabTable._copy.put(c, value: c.world.fresh!.id);
      ActivationSteps.mark(ActivationStep.duplicateTab,
          outcome: StepOutcome.go, site: model);
      await _runTabFlow(c, from: TabPlace.tDupRead);
    });
  }

  /// A copy of [source], not yet listed, so its key is built from its own
  /// host rather than looked up in the list.
  static SiteTab _copyOf(SiteTab source) {
    return SiteTab(
      url: source.url,
      title: source.title,
      parentId: source.parentId,
      hostSiteId: source.hostSiteId,
      openerSiteId: source.openerSiteId,
      homeUrl: source.homeUrl,
    );
  }

  /// Open a long-pressed link in a background tab under the tab it came from
  /// (TAB-006), running as [hostSiteId]: the tab it came from for a link in
  /// its domain, another of the user's sites for one in theirs (LIR-032).
  /// Costs nothing until it is first opened: no webview is built and no state
  /// file is written.
  Future<void> openLinkInNewTab(
    WebViewModel model, {
    required String url,
    required SiteId? hostSiteId,
    SiteId? openerSiteId,
    String? homeUrl,
  }) async {
    await _parkChild(model, child: () => SiteTab(
          url: url,
          parentId: model.activeTabId,
          hostSiteId: hostSiteId == model.siteId ? null : hostSiteId,
          openerSiteId: openerSiteId,
          homeUrl: homeUrl,
        ));
  }

  /// Open the page Back would go to as a parked child of the site's current
  /// tab (TAB-020), running as that tab runs. The page on screen stays, as it
  /// does for a link opened in a new tab.
  Future<void> openBackInNewTab(WebViewModel model) async {
    if (!enabledFor(model)) return;
    final source = model.activeTab;
    final back = await model.controller?.backEntry();
    if (back == null || !_host.mounted) return;
    await _parkChild(model, child: () {
      // The history read belongs to the tab that was active then.
      if (model.activeTabId != source.id) return null;
      return SiteTab(
        url: back.url,
        title: back.title,
        parentId: source.id,
        hostSiteId: source.hostSiteId,
        openerSiteId: source.openerSiteId,
        homeUrl: source.homeUrl,
      );
    });
  }

  /// Insert the tab [child] makes into [model]'s tree under its parent,
  /// parked, and offer to switch to it (TAB-006): the [TabTable.tabInputs]
  /// parked-child input and its landing (pLand). [child] runs once no tab
  /// handler is in flight, which may have written back a list read before
  /// this insert; it returns null when the tab no longer belongs there. The
  /// insert may not be lost to a close in flight, so it waits for a free
  /// gate and asks in the turn it finds one, as an owner-run move does.
  Future<void> _parkChild(WebViewModel model,
      {required SiteTab? Function() child}) async {
    while (_gate.busy) {
      await _gate.idle();
    }
    if (!_host.mounted || !_sites.models.contains(model)) return;
    final tab = child();
    if (tab == null) return;
    final c = StepContext(TabFlow(this, site: model)..fresh = tab);
    final next = TabTable.tabInputs.runInput(c, from: TabPlace.parkChild);
    await _gate.hold(() => _runTabFlow(c, from: next));
  }

  /// The parked child joined the list: the page redraws and offers it.
  void _parked(StepView<TabFlow> c) {
    final flow = TabTable._flow.from(c);
    final tab = flow.fresh!;
    LogTag.tabs.debug(
        'Opened a background tab under ${tab.parentId} in "${flow.site.name}"',
        sensitive: true);
    _host.rebuild();
    flow
      ..commitAfter = true
      ..offer = tab.id;
  }

  /// Apply a close the engine has already decided: [TabTable.tabFlow] from the
  /// removal of the closed tabs' files, which re-binds the webview when the
  /// tab on screen was among them.
  Future<void> _applyTabClose({
    required WebViewModel model,
    required TabCloseResult result,
  }) async {
    if (result.closedIds.isEmpty) return;
    final c = StepContext(
      TabFlow(this, site: model)
        ..result = result
        ..dropped = {
          for (final id in result.closedIds) id: model.stateKeyForTab(id),
        },
    );
    TabTable._kind.put(c, value: FlowKind.tab);
    TabTable._site.put(c, value: model);
    TabTable._tab.put(
      c,
      value: result.activeChanged ? model.activeTabId : result.closedIds.first,
    );
    TabTable._keep.put(c, value: false);
    TabTable._rest.put(c, value: result.tabs);
    TabTable._closing.put(c, value: result.closedIds);
    TabTable._ranAs.put(c, value: model.tabHosts);
    await _runTabFlow(c, from: TabPlace.tClosed);
  }

  /// Close [tabId], or its subtree, in [model] (TAB-007). On the site on
  /// screen it is the [TabTable.tabInputs] input.
  Future<void> closeTab(WebViewModel model,
      {required TabId tabId, bool subtree = false}) async {
    if (!model.tabs.any((t) => t.id == tabId)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(
        TabFlow(this, site: model, requested: tabId, subtree: subtree),
      );
      final next = TabTable.tabInputs.runInput(c, from: TabPlace.closeTab);
      if (next == TabPlace.done) return;
      await _gate.hold(() => _runTabFlow(c, from: next));
      return;
    }
    if (_gate.busy) {
      ActivationSteps.mark(ActivationStep.closeTab,
          outcome: StepOutcome.busy, site: model);
      return;
    }
    await _gate.run(() async {
      if (!_sites.models.contains(model)) return;
      final result = subtree
          ? TabLifecycleEngine.closeSubtree(model.tabs,
              activeTabId: model.activeTabId, closeId: tabId)
          : TabLifecycleEngine.closeTab(model.tabs,
              activeTabId: model.activeTabId, closeId: tabId);
      ActivationSteps.mark(ActivationStep.closeTab,
          outcome: StepOutcome.go, site: model);
      await _applyTabClose(model: model, result: result);
    });
  }

  /// A tab and its subtree dragged to another place in its site's tree
  /// (TAB-015). Only the tree changes: no webview, host or state key does.
  bool moveTab(WebViewModel model,
      {required TabId tabId, required TabDrop drop}) {
    if (_gate.busy || !enabledFor(model)) return false;
    final moved = TabLifecycleEngine.drop(model.tabs, tabId: tabId, drop: drop);
    if (moved == null) return false;
    WebViewModel.tabsCell.rearrange(at: model, to: moved);
    _host.rebuild();
    unawaited(_host.commitSites(const SitesEdited()));
    return true;
  }

  /// A back gesture that ran out of page history is spent on the tabs before
  /// NAV-001 / NAV-009 get it: back where a jump from the Tabs sheet came
  /// from (TAB-019), else closing a tab opened from another (TAB-007).
  Future<bool> backAtTabStart() async {
    if (await _returnFromJumpOnBack()) return true;
    if (!_host.mounted) return false;
    return _closeChildTabOnBack();
  }

  /// TAB-019: at the start of a tab the Tabs sheet jumped to, Back goes to
  /// the tab the jump came from. Neither tab closes.
  Future<bool> _returnFromJumpOnBack() async {
    if (!enabledFor(_sites.shown) || _gate.busy) return false;
    final model = _sites.shown!;
    final back = wayBackFrom(model);
    if (back == null) return false;
    final from = _sites.byId(back.fromSiteId);
    if (from == null || !from.tabs.any((t) => t.id == back.fromTabId)) {
      // Where the jump came from is gone, so the gesture does what it would
      // have done without one.
      _returns = const [];
      return false;
    }
    LogTag.navigation.debug(
        'Back gesture: at the start of a tab opened from the Tabs sheet; '
        'back where it was opened from');
    await openTab(from, tabId: back.fromTabId);
    return true;
  }

  /// A back gesture that ran out of page history. Returns true when it was
  /// spent closing a tab the user had opened from another one, which is what a
  /// browser does with a tab opened from a link (TAB-007). A root tab falls
  /// through to NAV-001 and whatever the NAV-009 setting says.
  Future<bool> _closeChildTabOnBack() async {
    if (!enabledFor(_sites.shown)) return false;
    // A close already running owns the tab list; reporting the gesture as
    // spent here would swallow it for nothing.
    if (_gate.busy) return false;
    final model = _sites.shown!;
    if (TabLifecycleEngine.backAtHistoryStart(model.tabs,
            activeTabId: model.activeTabId) !=
        TabBackAction.closeAndActivateParent) {
      return false;
    }
    LogTag.navigation.debug(
        'Back gesture: at history start in a tab opened from another; closing it');
    await closeTab(model, tabId: model.activeTabId);
    return true;
  }

  /// A tab switch's one turn: the bytes read queued for the target, the
  /// old webview gone, the rebuild frame building one for the target.
  void _rebind(CommitView<TabFlow> c) {
    final flow = TabTable._flow.from(c);
    final model = flow.site;
    model.activeTab.lastActiveAt = DateTime.now();
    // Queued before the dispose: `restoreState` only applies to a freshly
    // created controller, and the dispose is what makes the next build create
    // one. Nothing queued means the rebuild loads the tab's URL with an empty
    // history, which is what a brand-new tab wants.
    if (TabTable._label.of(c) case final bytes?) {
      model.tabBinding.queue(bytes, tab: TabTable._tab.of(c), commit: c.commit);
    }
    model.disposeWebView(commit: c.commit);
    _host.rebuild();
    flow
      ..rebound = true
      ..commitAfter = true;
  }

  /// [_rebind] onto a tab that runs as another site, the slot out of the
  /// loaded sites (LIR-024); the arm's [Spawn] activates it again.
  void _rebindAs(CommitView<TabFlow> c) {
    _host.noteUnloaded(TabTable._flow.from(c).site, why: 'identity change');
    _rebind(c);
  }

  /// A close that re-bound nothing: the list is in, the page redraws.
  void _closed(StepView<TabFlow> c) {
    final flow = TabTable._flow.from(c);
    LogTag.tabs.debug(
        'Closed ${TabTable._closing.of(c).length} tab(s) in "${flow.site.name}"; '
        '${flow.site.tabs.length} left',
        sensitive: true);
    _host.rebuild();
    flow.commitAfter = true;
  }

  /// The copy joined the list: the page redraws and offers it.
  void _duplicated(StepView<TabFlow> c) {
    final flow = TabTable._flow.from(c);
    LogTag.tabs.debug(
        'Duplicated ${TabTable._tab.of(c)} as ${TabTable._copy.of(c)} in "${flow.site.name}"',
        sensitive: true);
    _host.rebuild();
    flow
      ..commitAfter = true
      ..offer = TabTable._copy.of(c);
  }
}
