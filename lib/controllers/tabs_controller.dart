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
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tab_handling_gate.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/services/tab_return_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/tabs_sheet.dart' show TabsSheetSite;

/// What the tab flows ask of the page.
abstract interface class TabsHost implements PageHost {
  /// A capture of [model]'s back stack under its webview's tab; null when
  /// that tab keeps none.
  NavCapture? beginNavCapture(WebViewModel model);

  /// Drops a debounced capture queued for [siteId]: the webview it would
  /// read is about to go.
  void cancelPendingCapture(SiteId siteId);

  /// Drops [siteId]'s cached HTML snapshot while online.
  void evictCache(SiteId siteId);

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
  List<TabsSheetSite> sheetSites() {
    final view = _sites.filteredIndices();
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
  /// it leaves parks with its back stack, as for New tab.
  Future<void> landOnHomeTab(WebViewModel model) async {
    final landing = TabLifecycleEngine.homeLanding(
        model.tabs, activeTabId: model.activeTabId, initUrl: model.initUrl);
    if (landing == null) return;
    if (_gate.busy) {
      LogTag.tabs.debug(
          'Home landing for "${model.name}" skipped: a tab change is running',
          sensitive: true);
      return;
    }
    await _gate.run(() async {
      if (!_sites.models.contains(model)) return;
      const commit = Commit.unmodeled(Unmodeled.homeLanding);
      WebViewModel.tabsCell.write(at: model, to: landing.tabs, commit: commit);
      if (identical(model, _sites.shown) || _sites.loaded.contains(model)) {
        await switchActiveTab(model, targetTabId: landing.activeTabId);
        return;
      }
      WebViewModel.activeTabCell
          .write(at: model, to: landing.activeTabId, commit: commit);
      model.activeTab.lastActiveAt = DateTime.now();
    });
  }

  /// Move [model]'s webview from whatever tab it is on to [targetTabId]:
  /// [tabFlow] from its capture, or from its nav read when the tab being
  /// left is being closed ([captureOutgoing] false: its stack is going away
  /// with it). [tabs] replaces the list in the same turn as the active id.
  Future<void> switchActiveTab(
    WebViewModel model, {
    required TabId targetTabId,
    List<SiteTab>? tabs,
    bool captureOutgoing = true,
  }) async {
    if (!(tabs ?? model.tabs).any((t) => t.id == targetTabId)) return;
    final c = StepContext(TabFlow(this, site: model));
    _kind.put(c, value: FlowKind.tab);
    _site.put(c, value: model);
    _tab.put(c, value: targetTabId);
    _keep.put(c, value: captureOutgoing);
    if (tabs != null) _rest.put(c, value: tabs);
    await _runTabFlow(c, from: captureOutgoing ? TabPlace.tCap : TabPlace.tNav);
  }

  /// Runs [tabFlow] from [from] and what follows its end: the shell and
  /// the save a rebind owes, the offer a duplicate makes.
  Future<void> _runTabFlow(StepContext<TabFlow> c, {required TabPlace from}) async {
    await tabFlow.run(c, from: from);
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
  Future<void> reconcileLinkTabs() async {
    if (_gate.busy) {
      _gate.deferUntilIdle(() {
        if (_host.mounted) unawaited(reconcileLinkTabs());
      });
      return;
    }
    await _gate.run(() async {
      final dropped = <String>[];
      var changed = false;
      // One synchronous pass over every tab list: nothing can interleave
      // between reading what a tab runs as and rewriting it.
      for (final owner in _sites.models) {
        for (final tab in owner.tabs) {
          if (!tab.followsOpener) continue;
          final opener = _sites.byId(tab.openerSiteId!);
          if (opener == null) {
            // The opener is gone: nothing decides for the tab any more, so it
            // keeps the container it has (LIR-023 closes it if that is gone).
            tab.openerSiteId = null;
            changed = true;
            continue;
          }
          final home = tab.homeUrl!;
          final runsAs = LinkIntentDispatchEngine.linkTabRunsAs(
            homeUrl: Uri.parse(home),
            homeNavigationDomain: getNormalizedDomain(home),
            routeOutboundLinks: opener.effectiveRouteOutboundLinks,
            containersActive: _sites.useContainers,
            opener: SiteRoute(opener),
            openerPrefs: opener.outboundPreferences,
            hosts: () => _host.tabHostsIn(owner, opener: opener),
            current: tab.hostSiteId ?? owner.siteId,
          );
          final host = runsAs == owner.siteId ? null : runsAs;
          if (host == tab.hostSiteId) continue;
          final identityBefore = owner.runningIdentity;
          dropped.add(owner.stateKeyForTab(tab.id));
          LogTag.tabs.debug('Tab ${tab.id} of "${owner.name}" now runs as '
              '${host ?? owner.siteId} (opener ${opener.siteId})',
              sensitive: true);
          final active = tab.id == owner.activeTabId;
          if (active) _host.cancelPendingCapture(owner.siteId);
          tab.hostSiteId = host;
          changed = true;
          if (active && !identical(identityBefore, owner.runningIdentity)) {
            _letGoOfIdentity(owner);
          }
        }
      }
      if (!changed) return;
      for (final key in dropped) {
        await navStates.removeState(key);
      }
      if (!_host.mounted) return;
      _host.rebuild();
      await _host.commitSites(const SitesEdited());
    });
  }

  /// [model]'s slot runs as another site from this turn, so its webview,
  /// built as the one it ran as, goes in the same turn (LIR-024): a plan
  /// between the two would read the new identity's route for a webview on
  /// the old one. Under one process-wide proxy the slot also leaves the
  /// loaded sites, so nothing builds it on its new route beside the sites
  /// it contends with.
  void _letGoOfIdentity(WebViewModel model) {
    _host.evictCache(model.siteId);
    final global = residency.proxyTopology is ProcessGlobalProxy;
    if (global &&
        _sites.retired(
          model,
          commit: const Commit.unmodeled(Unmodeled.identityChange),
        )) {
      _host.noteUnloaded(model, why: 'identity change');
    }
    model.disposeWebView(
      commit: const Commit.unmodeled(Unmodeled.identityChange),
    );
    if (global) _reopen(model);
  }

  /// [model] runs as another site from this turn. On screen, or opening
  /// for an activation planned for the identity it left ([_reopened]), it
  /// is activated again in the same turn, the input before any await: the
  /// new activation plans for the new route and supersedes the old, and no
  /// event sees the screen on a site neither loaded nor opening. The tab
  /// switch's rebind does this as its [Spawn].
  void _reopen(WebViewModel model) {
    final c = StepContext(TabFlow(this, site: model));
    _site.put(c, value: model);
    if (_reopened.run(c)) unawaited(_host.activate(model));
  }

  /// Show [model]'s [tabId]. Used by the tab list, and by Back
  /// going back along the trail of jumps it made (TAB-019). On the site on
  /// screen it is the [tabInputs] input; a site off screen is shown first.
  Future<void> openTab(WebViewModel model, {required TabId tabId}) async {
    if (!model.tabs.any((t) => t.id == tabId)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(TabFlow(this, site: model, requested: tabId));
      final next = tabInputs.runInput(c, from: TabPlace.openTab);
      if (next == TabPlace.done) return;
      final trail = TabReturnEngine.afterOpen(
        _returns,
        fromSiteId: model.siteId,
        fromTabId: model.activeTabId,
        toSiteId: model.siteId,
        toTabId: tabId,
        webspaceId: _sites.selectedWebspaceId,
      );
      await _gate.run(() => _runTabFlow(c, from: next));
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
    if (_sites.loaded.contains(model)) {
      await switchToOwnerRunTab(model);
      return;
    }
    model.bindOwnerRunTab();
  }

  /// [bindOwnerRunTab] for a slot that may be live: the hosted tab's back
  /// stack is captured and the webview rebuilt as [model].
  Future<void> switchToOwnerRunTab(WebViewModel model) async {
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

  /// Open a new tab at the site's home page, or at [url] for a search
  /// (TAB-005, LIR-030). The tab the user was on is kept: it parks, with its
  /// back stack captured. On the site on screen it is the [tabInputs] input.
  Future<void> newTab(WebViewModel model, {String? url}) async {
    if (!enabledFor(model)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(TabFlow(this, site: model, url: url));
      final next = tabInputs.runInput(c, from: TabPlace.newTab);
      if (next == TabPlace.done) return;
      await _gate.run(() => _runTabFlow(c, from: next));
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
  /// (S6), a link into another of the user's sites (LIR-032).
  Future<void> openChildTab(
    WebViewModel owner, {
    required String url,
    SiteId? hostSiteId,
    TabId? parentTabId,
    SiteId? openerSiteId,
    String? homeUrl,
  }) async {
    if (!owner.effectiveTabsEnabled) return;
    await _gate.run(() async {
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
      WebViewModel.tabsCell.write(
          at: owner,
          to: TabLifecycleEngine.insertChild(owner.tabs, tab: tab),
          commit: const Commit.unmodeled(Unmodeled.childTab));
      LogTag.tabs.debug('Opened a child tab of "${owner.name}"'
          '${tab.hostSiteId == null ? '' : ' run as ${tab.hostSiteId}'}',
          sensitive: true);
      await switchActiveTab(owner, targetTabId: tab.id);
    });
  }

  /// Copy the site's current tab, back stack included, into a new tab beside
  /// it (TAB-010). The copy opens parked, so the page on screen stays put and
  /// the copy costs a record plus a state file until it is first opened. On
  /// the site on screen it is the [tabInputs] input; off screen the same
  /// flow from its read.
  Future<void> duplicateTab(WebViewModel model) async {
    if (!enabledFor(model)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(TabFlow(this, site: model));
      final next = tabInputs.runInput(c, from: TabPlace.duplicateTab);
      if (next == TabPlace.done) return;
      await _gate.run(() => _runTabFlow(c, from: next));
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
      _kind.put(c, value: FlowKind.tab);
      _site.put(c, value: model);
      _tab.put(c, value: model.activeTabId);
      _copy.put(c, value: c.world.fresh!.id);
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
  /// parked, and offer to switch to it (TAB-006). [child] runs once no tab
  /// handler is in flight, which may have written back a list read before
  /// this insert; it returns null when the tab no longer belongs there.
  Future<void> _parkChild(WebViewModel model,
      {required SiteTab? Function() child}) async {
    final tab = await _gate.runWhenIdle(() async {
      if (!_host.mounted || !_sites.models.contains(model)) return null;
      final tab = child();
      if (tab == null) return null;
      WebViewModel.tabsCell.write(
          at: model,
          to: TabLifecycleEngine.insertChild(model.tabs, tab: tab),
          commit: const Commit.unmodeled(Unmodeled.childTab));
      _host.rebuild();
      return tab;
    });
    if (tab == null) return;
    LogTag.tabs.debug(
        'Opened a background tab under ${tab.parentId} in "${model.name}"',
        sensitive: true);
    await _host.commitSites(const SitesEdited());
    _host.offerOpenTab(model, tabId: tab.id);
  }

  /// Apply a close the engine has already decided: [tabFlow] from the
  /// removal of the closed tabs' files, which re-binds the webview when the
  /// tab on screen was among them.
  Future<void> _applyTabClose({
    required WebViewModel model,
    required TabCloseResult result,
  }) async {
    if (result.closedIds.isEmpty) return;
    final c = StepContext(TabFlow(this, site: model)..result = result);
    _kind.put(c, value: FlowKind.tab);
    _site.put(c, value: model);
    _tab.put(
      c,
      value: result.activeChanged ? model.activeTabId : result.closedIds.first,
    );
    _keep.put(c, value: false);
    _rest.put(c, value: result.tabs);
    _closing.put(c, value: result.closedIds);
    await _runTabFlow(c, from: TabPlace.tRemove);
  }

  /// Close [tabId], or its subtree, in [model] (TAB-007). On the site on
  /// screen it is the [tabInputs] input.
  Future<void> closeTab(WebViewModel model,
      {required TabId tabId, bool subtree = false}) async {
    if (!model.tabs.any((t) => t.id == tabId)) return;
    if (identical(model, _sites.shown)) {
      final c = StepContext(
        TabFlow(this, site: model, requested: tabId, subtree: subtree),
      );
      final next = tabInputs.runInput(c, from: TabPlace.closeTab);
      if (next == TabPlace.done) return;
      await _gate.run(() => _runTabFlow(c, from: next));
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
    WebViewModel.tabsCell.write(
        at: model, to: moved, commit: const Commit.unmodeled(Unmodeled.tabMove));
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

  // ── The tab flows' leaves: the model's variables as this controller reads
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

  /// The tabs' state files, the model's `file` (TAB-003).
  static final _files = Port<WebViewStateStorage, TabFlow>(
    'files',
    reads: {ModelVar.file},
    changes: {ModelVar.file},
    of: (w) => w._c.navStates,
  );

  static Expr<WebViewModel, TabFlow> get _current => Expr.op(
        'current',
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
  static final _reopened =
      _currentVar.value.eq(_site.value) |
      _marker.value.part('t', get: (m) => m?.target).eq(_site.value);
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
  static const _label = Field<Uint8List?, TabFlow>(FlowField.label);
  static const _wrote = Field<bool, TabFlow>(FlowField.wrote);

  static final _yes = Expr.constant<bool, TabFlow>(true);
  static final _no = Expr.constant<bool, TabFlow>(false);
  static final _noBytes = Expr.constant<Uint8List?, TabFlow>(null, tla: '0');

  /// The bytes' label, the model's alone: the code holds bytes.
  static final _labelTla = Expr<TabId?, TabFlow>(
    run: (_) => throw StateError('the label is the model\'s'),
    tla: 'fl[f].label',
    reads: Reads.none,
  );

  /// The input is the site on screen's; the model follows only the sites
  /// a config names (`Tabbed`).
  static final _tabbedCurrent = Expr.op<bool, TabFlow>(
    'current \\in Tabbed',
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
    'HasFresh(current)',
    run: (_) => true, reads: const Reads(vars: {ModelVar.current},
    base: {BaseOp.hasFresh}),
  );
  static final _mint = Expr.op<TabId, TabFlow>(
    'Mint(current)',
    run: (c) => _flow.from(c).fresh!.id,
    reads: const Reads(vars: {ModelVar.current}, base: {BaseOp.mint}),
  );
  static final _mintSite = Expr.op<TabId, TabFlow>(
    'Mint(fl[f].site)',
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

  /// The lists the flows install, as the engine orders them and as the
  /// model's sets read them; each checks its ids against its reading.
  static final _withFresh = Expr<List<SiteTab>, TabFlow>(
    run: (c) {
      final f = _flow.from(c);
      return _asRead(
        [...f.site.tabs, f.fresh!],
        ids: {for (final t in f.site.tabs) t.id, f.fresh!.id},
      );
    },
    tla: 'tabs[current] \\cup {Mint(current)}',
    reads: const Reads(vars: {ModelVar.current, ModelVar.tabs}, base: {BaseOp.mint}),
  );
  static final _withCopy = Expr<List<SiteTab>, TabFlow>(
    run: (c) {
      final f = _flow.from(c);
      return _asRead(
        TabLifecycleEngine.insertAfter(
          f.site.tabs,
          anchorId: _tab.of(c),
          tab: f.fresh!,
        ),
        ids: {for (final t in f.site.tabs) t.id, f.fresh!.id},
      );
    },
    tla: 'tabs[fl[f].site] \\cup {fl[f].copy}',
    reads: const Reads(vars: {ModelVar.tabs}),
  );
  static final _resultTabs = Expr<List<SiteTab>, TabFlow>(
    run: (c) => _flow.from(c).result!.tabs,
    tla: 'tabs[current] \\ {s}',
    reads: const Reads(vars: {ModelVar.current, ModelVar.tabs}),
  );
  static final _closedIds = Expr<List<TabId>, TabFlow>(
    run: (c) => _flow.from(c).result!.closedIds,
    tla: '{s}',
    reads: Reads.none,
  );
  static final _survivors = _tabIds(_current).without(_chosenTab);
  static final _restIds = Expr<List<TabId>, TabFlow>(
    run: (c) => _rest.isSet(c) ? [for (final t in _rest.of(c)) t.id] : const [],
    tla: 'fl[f].rest',
    reads: Reads.none,
  );
  static final _resultTabsAgain = Expr<List<SiteTab>, TabFlow>(
    run: (c) => _rest.of(c),
    tla: 'fl[f].rest',
    reads: Reads.none,
  );
  static final _onlyFresh = Expr<List<SiteTab>, TabFlow>(
    run: (c) => [_flow.from(c).fresh!],
    tla: '{Mint(fl[f].site)}',
    reads: const Reads(base: {BaseOp.mint}),
  );
  static final _installed = Expr<List<SiteTab>, TabFlow>(
    run: (c) => _rest.isSet(c) ? _rest.of(c) : _flow.from(c).site.tabs,
    tla: 'IF fl[f].rest = {} THEN tabs[fl[f].site] ELSE fl[f].rest',
    reads: const Reads(vars: {ModelVar.tabs}),
  );

  /// The tabs the target has to be among: the list being installed, else
  /// the site's. A page gone away has none.
  static final _targetIn = Expr<List<TabId>, TabFlow>(
    run: (c) => !_page.from(c).mounted
        ? const []
        : _rest.isSet(c)
            ? [for (final t in _rest.of(c)) t.id]
            : [for (final t in _flow.from(c).site.tabs) t.id],
    tla: 'IF fl[f].rest = {} THEN tabs[fl[f].site] ELSE fl[f].rest',
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
  static final _sourceStays = Expr<bool, TabFlow>(
    run: (c) =>
        _page.from(c).mounted &&
        _flow.from(c).site.tabs.any((t) => t.id == _tab.of(c)),
    tla: 'fl[f].tab \\in tabs[fl[f].site]',
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

  /// LIR-024: a tab switch on a routed site may change the slot's identity
  /// under a process-global proxy; the pages route none. Only under
  /// containers does a tab run as another site ([mayHost]).
  static final _identityChanges =
      Constant<bool, TabFlow>(
        ModelConst.containers,
        read: (w) => w._c._sites.useContainers,
      ).value &
      Expr.op<bool, TabFlow>(
        'fl[f].site \\in Routed',
        run: (c) {
          final site = _site.of(c);
          if (!_page.from(c).processGlobal) return false;
          final target = _targetOf(c);
          return target != null &&
              !identical(site.runningIdentity, site.hostOf(target) ?? site);
        },
        reads: Reads.none,
        needs: const {(of: ModelConst.routed, set: true)},
      );

  static String _copyKey(StepView<TabFlow> c) {
    final copy = _flow.from(c).fresh!;
    return webViewStateKey(copy.hostSiteId ?? _site.of(c).siteId, tabId: copy.id);
  }

  /// [list] as the model reads it: its ids are [ids].
  static List<SiteTab> _asRead(List<SiteTab> list, {required Set<TabId> ids}) {
    assert(
      {for (final t in list) t.id}.length == ids.length &&
          list.every((t) => ids.contains(t.id)),
      'the list installed is not the set the model reads',
    );
    return list;
  }

  /// A tab switch's one turn: the bytes read queued for the target, the
  /// old webview gone, the rebuild frame building one for the target.
  void _rebind(CommitView<TabFlow> c) {
    final flow = _flow.from(c);
    final model = flow.site;
    model.activeTab.lastActiveAt = DateTime.now();
    // Queued before the dispose: `restoreState` only applies to a freshly
    // created controller, and the dispose is what makes the next build create
    // one. Nothing queued means the rebuild loads the tab's URL with an empty
    // history, which is what a brand-new tab wants.
    if (_label.of(c) case final bytes?) {
      model.tabBinding.queue(bytes, tab: _tab.of(c), commit: c.commit);
    }
    // The cached HTML snapshot is per site, so it holds the page the *other*
    // tab was on; leaving it would flash that page into this tab's first
    // frame. Offline it is the only thing renderable, so it stays.
    _host.evictCache(model.siteId);
    model.disposeWebView(commit: c.commit);
    _host.rebuild();
    flow
      ..rebound = true
      ..commitAfter = true;
  }

  /// [_rebind] onto a tab that runs as another site, the slot out of the
  /// loaded sites (LIR-024); the arm's [Spawn] activates it again.
  void _rebindAs(CommitView<TabFlow> c) {
    _host.noteUnloaded(_flow.from(c).site, why: 'identity change');
    _rebind(c);
  }

  /// A close that re-bound nothing: the list is in, the page redraws.
  void _closed(StepView<TabFlow> c) {
    final flow = _flow.from(c);
    LogTag.tabs.debug(
        'Closed ${_closing.of(c).length} tab(s) in "${flow.site.name}"; '
        '${flow.site.tabs.length} left',
        sensitive: true);
    _host.rebuild();
    flow.commitAfter = true;
  }

  /// The copy joined the list: the page redraws and offers it.
  void _duplicated(StepView<TabFlow> c) {
    final flow = _flow.from(c);
    LogTag.tabs.debug(
        'Duplicated ${_tab.of(c)} as ${_copy.of(c)} in "${flow.site.name}"',
        sensitive: true);
    _host.rebuild();
    flow
      ..commitAfter = true
      ..offer = _copy.of(c);
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
              f.fresh = _copyOf(f.site.activeTab);
            }),
            _mintedBump,
            ..._starts,
            _tab.becomes(_active.at(_current)),
            _copy.becomes(_mint),
          ],
          next: to(TabPlace.tDupRead),
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
      begin: (c) => _page.from(c).beginCapture(_site.of(c)),
      marks: _site.value,
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
              _tabs.except(_site.value, to: _resultTabsAgain),
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
              [_tabs.except(_site.value, to: _withCopy)],
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
          writes: [TabVars.removed(_site.value, tab: _copy.value)],
        ),
        site: _site.value,
        otherwise: Otherwise(StepOutcome.none, then: [], next: to(TabPlace.done)),
      ),
    },
  );

}


/// The places a tab flow waits at, as `activation.tla` names them: the
/// inputs, the switch (its capture, its nav read, the slot's reroute, the
/// rebind), a close's removals and a duplicate's read, write and insert.
enum TabPlace {
  openTab,
  newTab,
  closeTab,
  duplicateTab,
  tCap,
  tCapSave,
  tNav,
  tRebind,
  tRemove,
  tDupRead,
  tDupSave,
  tDupInsert,
  tDupRemove,
  done,
}

/// What a tab flow's steps run against: the controller, the site, what the
/// handler was asked, and what the flow found on its way.
/// What a tab flow keeps for itself: the site and tab its handler named,
/// what it minted and decided, and what it leaves the handler to finish.
/// Code-only, none of it a variable of the model.
abstract interface class TabState {
  WebViewModel get site;
  TabId? get requested;
  String? get url;
  bool get subtree;
  abstract SiteTab? fresh;
  abstract TabCloseResult? result;
  abstract bool rebound;
  abstract bool commitAfter;
  abstract TabId? offer;
}

/// What the tab steps ask of the page and do to it, through their `page`
/// port: whether it is still there, the gate, whether the proxy is the
/// process's, a capture's start, and the redraws and rebinds a step's act
/// finishes with.
final class TabCalls {
  TabCalls(this._c);

  final TabsController _c;

  bool get mounted => _c._host.mounted;
  bool get gateBusy => _c._gate.busy;
  bool get processGlobal => _c.residency.proxyTopology is ProcessGlobalProxy;
  bool isShown(WebViewModel site) => identical(site, _c._sites.shown);
  bool isLoaded(WebViewModel site) => _c._sites.loaded.contains(site);

  NavCapture? beginCapture(WebViewModel site) {
    _c._host.cancelPendingCapture(site.siteId);
    return _c._host.beginNavCapture(site);
  }

  void rebind(CommitView<TabFlow> c) => _c._rebind(c);
  void rebindAs(CommitView<TabFlow> c) => _c._rebindAs(c);

  /// An activation of [site], its input run before this returns.
  void activate(WebViewModel site) => unawaited(_c._host.activate(site));
  void closed(StepView<TabFlow> c) => _c._closed(c);
  void duplicated(StepView<TabFlow> c) => _c._duplicated(c);
}

final class TabFlow implements Capturing, TabState {
  TabFlow(
    this._c, {
    required this.site,
    this.requested,
    this.url,
    this.subtree = false,
  });

  final TabsController _c;
  @override
  final WebViewModel site;

  @override
  NavCapture? capture;

  /// The tab the handler names (openTab, closeTab).
  @override
  final TabId? requested;

  /// A new tab's URL when not the site's home (a search, LIR-030).
  @override
  final String? url;

  /// Whether a close takes the tab's subtree with it.
  @override
  final bool subtree;

  /// A tab this flow minted: a new tab, the home tab after the last close,
  /// a duplicate's copy.
  @override
  SiteTab? fresh;

  /// The close the engine decided.
  @override
  TabCloseResult? result;

  /// What the flow leaves for the handler to finish: the shell and the
  /// save a rebind owes, the offer a duplicate makes.
  @override
  bool rebound = false;
  @override
  bool commitAfter = false;
  @override
  TabId? offer;
}
