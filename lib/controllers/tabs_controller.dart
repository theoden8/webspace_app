import 'dart:async';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/experimental_features_service.dart';
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

/// What the tab flows ask of the page.
abstract interface class TabsHost implements PageHost {
  /// Saves [model]'s back stack under its active tab's key.
  Future<bool> captureNavState(WebViewModel model);

  /// Drops a debounced capture queued for [siteId]: the webview it would
  /// read is about to go.
  void cancelPendingCapture(String siteId);

  /// Drops [siteId]'s cached HTML snapshot while online.
  void evictCache(String siteId);

  void enterFullscreen();

  Future<void> activate(int index);

  Future<void> saveCurrentIndex();

  Future<void> saveSelectedWebspace();

  /// WEBSPACE-012: switches to "All" when the selected webspace hides
  /// [model].
  Future<void> revealSite(WebViewModel model, int index);

  /// Tells the user a tab opened in the background, with a way to it.
  void offerOpenTab(WebViewModel model, String tabId);

  /// The sites that can run a link of [opener]'s as a tab in [owner]'s tree
  /// (LIR-032).
  List<DispatchableSite> tabHostsIn(WebViewModel owner, WebViewModel opener);

  /// [model] left the loaded set outside the unload funnel, for [why].
  void noteUnloaded(WebViewModel model, String why);
}

/// A site's tabs (TAB-002..TAB-019): one container and one webview per site,
/// shared by its tabs. The active tab is the one bound to the webview; every
/// other tab is a record plus, when it has a back stack worth keeping, one
/// encrypted state file. So a tab switch is the savedForRestore walk applied
/// per tab (capture, dispose, queue, rebuild) and the number of live webviews
/// never moves.
class TabsController {
  TabsController(
    this._sites,
    this._host, {
    required this.navStates,
    required this.residency,
  });

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
      TabReturnEngine.wayBack(_returns, model.siteId, model.activeTabId);

  /// Tabs are experimental (TAB-012, DEVTOOLS-011): developer mode and the Site
  /// tabs switch. Read on every use, so the switch applies without a restart.
  /// Web search ships behind it too (LIR-029): a search's results are a
  /// hosted tab, the feature tabs exist for.
  bool get featureEnabled => ExperimentalFeaturesService.instance
      .isEnabled(ExperimentalFeature.siteTabs);

  /// Whether [model] has tabs: the feature is on and the site is not run as an
  /// app (TAB-013). Off, every way into its tabs is closed and it shows its
  /// active tab alone.
  bool enabledFor(WebViewModel model) =>
      featureEnabled && model.effectiveTabsEnabled;

  bool enabledAt(int? index) =>
      index != null &&
      index >= 0 &&
      index < _sites.models.length &&
      enabledFor(_sites.models[index]);

  /// Whether [host] may run a tab in [owner]'s tree (LIR-019): the container
  /// engine, a host with a persistent container of its own, and neither side
  /// in an archive.
  bool mayHost(WebViewModel host, WebViewModel owner) =>
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
        model.tabs, model.activeTabId, model.initUrl);
    if (landing == null) return;
    if (_gate.busy) {
      LogService.instance.log(
        'Tabs',
        'Home landing for "${model.name}" skipped: a tab change is running',
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }
    await _gate.run(() async {
      final index = _sites.models.indexOf(model);
      if (index < 0) return;
      model.tabs = landing.tabs;
      if (index == _sites.current || _sites.loaded.contains(index)) {
        await switchActiveTab(model, landing.activeTabId);
        return;
      }
      model.activeTabId = landing.activeTabId;
      model.activeTab.lastActiveAt = DateTime.now();
    });
  }

  /// Move [model]'s webview from whatever tab it is on to [targetTabId].
  ///
  /// [captureOutgoing] is false only when the tab being left is being closed —
  /// its stack is going away with it, so capturing it would write a file the
  /// caller then has to delete.
  Future<void> switchActiveTab(
    WebViewModel model,
    String targetTabId, {
    bool captureOutgoing = true,
  }) async {
    if (!model.tabs.any((t) => t.id == targetTabId)) return;
    if (captureOutgoing) {
      // A capture already queued for this site would fire against the webview
      // we are about to dispose and write under whichever key is current by
      // then; this one is the authoritative one.
      _host.cancelPendingCapture(model.siteId);
      await _host.captureNavState(model);
      if (!_host.mounted) return;
      if (!model.tabs.any((t) => t.id == targetTabId)) return;
    }
    final identityBefore = model.runningIdentity;
    model.activeTabId = targetTabId;
    model.activeTab.lastActiveAt = DateTime.now();
    if (!await _applySlotIdentityChange(model, identityBefore)) return;
    // Queue before the dispose: `restoreState` only applies to a freshly
    // created controller, and `disposeWebView` is what makes the next build
    // create one. Nothing queued means the rebuild loads the tab's URL with an
    // empty history, which is what a brand-new tab wants.
    if (model.activeTabPersistsNavState) {
      final bytes = await navStates.loadState(model.activeStateKey);
      if (!_host.mounted) return;
      if (bytes != null && model.activeTabId == targetTabId) {
        model.schedulePendingRestoreState(bytes);
      }
    }
    // The cached HTML snapshot is per site, so it holds the page the *other*
    // tab was on; leaving it would flash that page into this tab's first
    // frame. Offline it is the only thing renderable, so it stays.
    _host.evictCache(model.siteId);
    model.disposeWebView();
    // The rebuild is a fresh webview, so the site is back at the policy's
    // lowest tier whatever the pressure cascade had done to the one it
    // replaces. A site with no webview keeps the tier it was unloaded at.
    if (_sites.loaded.contains(_sites.models.indexOf(model))) {
      model.lifecycleState = SiteLifecycleState.resident;
    }
    if (!_host.mounted) return;
    _host.rebuild();
    // Only the site on screen owns the shell. An offscreen switch (a shortcut
    // landing a sibling at home) must not take the app into full screen.
    if (model.fullscreenMode &&
        _sites.models.indexOf(model) == _sites.current) {
      _host.enterFullscreen();
    }
    LogService.instance.log(
      'Tabs',
      'Bound "${model.name}" to tab $targetTabId (${model.tabs.length} tabs)',
      sensitivity: LogSensitivity.sensitive,
    );
    await _host.commitSites(const SitesEdited());
  }

  /// LIR-024: on a process-global proxy the slot's new identity may need
  /// another proxy. The visible slot runs PROXY-008 first; a background slot
  /// stays unloaded and rebuilds under it on its next activation. False when
  /// the page went away meanwhile.
  Future<bool> _applySlotIdentityChange(
    WebViewModel model,
    WebViewModel identityBefore,
  ) async {
    final slot = _sites.models.indexOf(model);
    if (identical(identityBefore, model.runningIdentity) ||
        slot < 0 ||
        residency.proxyTopology is! ProcessGlobalProxy) {
      return _host.mounted;
    }
    if (slot == _sites.current) {
      final plan =
          SiteUnloadEngine.plan(residency, SlotIdentityChanged(slot));
      if (!await SiteUnloadEngine.apply(residency, plan,
          isStale: () => !_host.mounted)) {
        return false;
      }
    } else {
      _sites.loaded.remove(slot);
      _host.noteUnloaded(model, 'identity change');
    }
    return _host.mounted;
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
      final identityBefore = <WebViewModel, WebViewModel>{};
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
            hosts: () => _host.tabHostsIn(owner, opener),
            current: tab.hostSiteId ?? owner.siteId,
          );
          final host = runsAs == owner.siteId ? null : runsAs;
          if (host == tab.hostSiteId) continue;
          if (tab.id == owner.activeTabId) {
            identityBefore.putIfAbsent(owner, () => owner.runningIdentity);
            _host.cancelPendingCapture(owner.siteId);
          }
          dropped.add(owner.stateKeyForTab(tab.id));
          LogService.instance.log(
            'Tabs',
            'Tab ${tab.id} of "${owner.name}" now runs as '
                '${host ?? owner.siteId} (opener ${opener.siteId})',
            sensitivity: LogSensitivity.sensitive,
          );
          tab.hostSiteId = host;
          changed = true;
        }
      }
      if (!changed) return;
      for (final key in dropped) {
        await navStates.removeState(key);
      }
      if (!_host.mounted) return;
      for (final entry in identityBefore.entries) {
        final model = entry.key;
        if (!_sites.models.contains(model)) continue;
        if (identical(entry.value, model.runningIdentity)) continue;
        if (!await _applySlotIdentityChange(model, entry.value)) return;
        _host.evictCache(model.siteId);
        model.disposeWebView();
      }
      if (!_host.mounted) return;
      _host.rebuild();
      await _host.commitSites(const SitesEdited());
    });
  }

  /// Show [tabId] of the site at [index]. Used by the tab list, and by Back
  /// going back along the trail of jumps it made (TAB-019).
  Future<void> openTab(int index, String tabId) async {
    await _gate.run(() async {
      if (index < 0 || index >= _sites.models.length) return;
      final model = _sites.models[index];
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
      if (index == _sites.current) {
        if (model.activeTabId == tabId) return;
        await switchActiveTab(model, tabId);
        _returns = trail;
        return;
      }
      // The site is not on screen. When it has no webview either, moving the
      // pointer before activating means the activation builds the right tab
      // directly — no load of the tab the site happened to be on, and no
      // dispose right after it.
      if (model.activeTabId != tabId && model.tabs.any((t) => t.id == tabId)) {
        if (_sites.loaded.contains(index)) {
          await switchActiveTab(model, tabId);
          if (!_host.mounted) return;
        } else {
          model.activeTabId = tabId;
          model.activeTab.lastActiveAt = DateTime.now();
          unawaited(_host.commitSites(const SitesEdited()));
        }
      }
      // An "In {site}" row can belong to a site this webspace hides. Going
      // back puts back the webspace the jump left, if it shows the site.
      if (back != null && back.leadsBackTo(model.siteId, tabId)) {
        await _returnToWebspace(back.webspaceId, model, index);
      } else {
        await _host.revealSite(model, index);
      }
      if (!_host.mounted) return;
      await _host.activate(index);
      if (!_host.mounted) return;
      _returns = trail;
      _host.rebuild();
      await _host.saveCurrentIndex();
    });
  }

  /// TAB-019: the way back from a jump restores the webspace the jump left
  /// when that still shows [model]; otherwise WEBSPACE-012 decides.
  Future<void> _returnToWebspace(
      String? webspaceId, WebViewModel model, int index) async {
    final ws = _sites.webspaces.where((w) => w.id == webspaceId).firstOrNull;
    if (ws == null ||
        webspaceId == _sites.selectedWebspaceId ||
        !(ws.isAll || ws.siteIndices.contains(index))) {
      await _host.revealSite(model, index);
      return;
    }
    _sites.selectedWebspaceId = webspaceId;
    _host.rebuild();
    await _host.saveSelectedWebspace();
  }

  /// S6: a link from a hosted tab back into [model]'s own domain opens as
  /// [model]'s child tab under it, running as [model], and takes the slot.
  Future<void> returnToOwner(WebViewModel model, String url) =>
      openChildTab(model, url);

  /// LIR-018: before an owner URL loads into [model]'s slot, the slot moves to
  /// a tab [model] runs itself: the nearest such ancestor, or a new root tab.
  Future<void> bindOwnerRunTab(WebViewModel model) async {
    if (!model.runsHostedTab && !model.runsForeignTab) return;
    final index = _sites.models.indexOf(model);
    if (_sites.loaded.contains(index)) {
      await switchToOwnerRunTab(model);
      return;
    }
    model.bindOwnerRunTab();
  }

  /// [bindOwnerRunTab] for a slot that may be live: the hosted tab's back
  /// stack is captured and the webview rebuilt as [model].
  Future<void> switchToOwnerRunTab(WebViewModel model) async {
    var id = TabLifecycleEngine.ownerRunTab(model.tabs, model.activeTabId,
        isForeign: model.isForeignTab);
    if (id == null) {
      final tab = SiteTab(url: model.initUrl);
      model.tabs = [...model.tabs, tab];
      id = tab.id;
    }
    await switchActiveTab(model, id);
  }

  /// LIR-023: close every hosted tab whose host is gone ([goneSiteId], or
  /// missing) or may no longer host, re-binding an owner whose active tab
  /// closed. Runs at startup, after an import, before a delete, after a
  /// site's settings change and after a move across the archive boundary.
  Future<void> closeIneligibleHostedTabs({String? goneSiteId}) =>
      _gate.runWhenIdle(() => _closeIneligibleHostedTabsHeld(goneSiteId));

  Future<void> _closeIneligibleHostedTabsHeld(String? goneSiteId) async {
    for (var i = 0; i < _sites.models.length; i++) {
      final model = _sites.models[i];
      if (!model.tabs.any((t) => t.hostSiteId != null)) continue;
      final result = TabLifecycleEngine.closeWhere(
        model.tabs,
        model.activeTabId,
        (t) {
          if (t.hostSiteId == null) return false;
          final host = model.hostOf(t);
          return host == null ||
              host.siteId == goneSiteId ||
              !mayHost(host, model);
        },
      );
      await _applyTabClose(i, model, result);
      if (!_host.mounted) return;
    }
  }

  /// Open a new tab at the site's home page, or at [url] for a search
  /// (TAB-005, LIR-030). The tab the user was on is kept: it parks, with its
  /// back stack captured.
  Future<void> newTab(int index, {String? url}) async {
    if (!enabledAt(index)) return;
    await _gate.run(() async {
      if (index < 0 || index >= _sites.models.length) return;
      final model = _sites.models[index];
      final tab = SiteTab(url: url ?? model.initUrl);
      model.tabs = [...model.tabs, tab];
      // A site with a live webview has to go through the switch even when it
      // is offscreen: moving `activeTabId` on its own would leave that webview
      // showing the tab it was on while the model says otherwise, and the
      // outgoing tab's back stack would never be captured.
      if (index != _sites.current && !_sites.loaded.contains(index)) {
        model.activeTabId = tab.id;
        await _host.activate(index);
        if (!_host.mounted) return;
        _host.rebuild();
        await _host.commitSites(const SitesEdited());
        return;
      }
      await switchActiveTab(model, tab.id);
      if (!_host.mounted) return;
      if (index != _sites.current) await _host.activate(index);
    });
  }

  /// A child tab of [owner]'s [parentTabId] (the active tab when it is gone
  /// or not given) at [url], running as [hostSiteId] or as [owner] itself,
  /// and switched to: a search's results (LIR-030), a link back to the owner
  /// (S6), a link into another of the user's sites (LIR-032).
  Future<void> openChildTab(
    WebViewModel owner,
    String url, {
    String? hostSiteId,
    String? parentTabId,
    String? openerSiteId,
    String? homeUrl,
  }) async {
    if (!enabledFor(owner)) return;
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
      owner.tabs = TabLifecycleEngine.insertChild(owner.tabs, tab);
      LogService.instance.log(
        'Tabs',
        'Opened a child tab of "${owner.name}"'
            '${tab.hostSiteId == null ? '' : ' run as ${tab.hostSiteId}'}',
        sensitivity: LogSensitivity.sensitive,
      );
      await switchActiveTab(owner, tab.id);
    });
  }

  /// Copy the site's current tab, back stack included, into a new tab beside
  /// it (TAB-010). The copy opens parked, so the page on screen stays put and
  /// the copy costs a record plus a state file until it is first opened.
  Future<void> duplicateTab(int index) async {
    if (!enabledAt(index)) return;
    await _gate.run(() async {
      if (index < 0 || index >= _sites.models.length) return;
      final model = _sites.models[index];
      final source = model.activeTab;
      final copy = SiteTab(
        url: source.url,
        title: source.title,
        parentId: source.parentId,
        hostSiteId: source.hostSiteId,
        openerSiteId: source.openerSiteId,
        homeUrl: source.homeUrl,
      );
      final copyKey = model.stateKeyForTab(copy.id);
      if (model.activeTabPersistsNavState) {
        // A loaded webview's back stack is newer than whatever was last saved
        // for it; an unloaded site's saved bytes are all there is.
        final bytes = _sites.loaded.contains(index)
            ? await model.captureNavigationState()
            : await navStates.loadState(model.activeStateKey);
        if (bytes != null) await navStates.saveState(copyKey, bytes);
      }
      if (!_host.mounted) return;
      if (!_sites.models.contains(model) ||
          !model.tabs.any((t) => t.id == source.id)) {
        unawaited(navStates.removeState(copyKey));
        return;
      }
      model.tabs = TabLifecycleEngine.insertAfter(model.tabs, source.id, copy);
      _host.rebuild();
      LogService.instance.log(
        'Tabs',
        'Duplicated ${source.id} as ${copy.id} in "${model.name}"',
        sensitivity: LogSensitivity.sensitive,
      );
      await _host.commitSites(const SitesEdited());
      _host.offerOpenTab(model, copy.id);
    });
  }

  /// Open a long-pressed link in a background tab under the tab it came from
  /// (TAB-006), running as [hostSiteId]: the tab it came from for a link in
  /// its domain, another of the user's sites for one in theirs (LIR-032).
  /// Costs nothing until it is first opened: no webview is built and no state
  /// file is written.
  Future<void> openLinkInNewTab(
    int index,
    String url, {
    required String? hostSiteId,
    String? openerSiteId,
    String? homeUrl,
  }) async {
    if (index < 0 || index >= _sites.models.length) return;
    final model = _sites.models[index];
    // A tab handler in flight may write back a list read before this insert.
    final tab = await _gate.runWhenIdle(() async {
      if (!_host.mounted || !_sites.models.contains(model)) return null;
      final tab = SiteTab(
        url: url,
        parentId: model.activeTabId,
        hostSiteId: hostSiteId == model.siteId ? null : hostSiteId,
        openerSiteId: openerSiteId,
        homeUrl: homeUrl,
      );
      model.tabs = TabLifecycleEngine.insertChild(model.tabs, tab);
      _host.rebuild();
      return tab;
    });
    if (tab == null) return;
    LogService.instance.log(
      'Tabs',
      'Opened a background tab under ${model.activeTabId} in "${model.name}"',
      sensitivity: LogSensitivity.sensitive,
    );
    await _host.commitSites(const SitesEdited());
    _host.offerOpenTab(model, tab.id);
  }

  /// Apply a close the engine has already decided, dropping the saved state of
  /// every tab that went and re-binding the webview when the one on screen was
  /// among them.
  Future<void> _applyTabClose(
    int index,
    WebViewModel model,
    TabCloseResult result,
  ) async {
    if (result.closedIds.isEmpty) return;
    for (final id in result.closedIds) {
      await navStates.removeState(model.stateKeyForTab(id));
    }
    if (!_host.mounted) return;
    model.tabs = result.tabs;
    LogService.instance.log(
      'Tabs',
      'Closed ${result.closedIds.length} tab(s) in "${model.name}"; '
          '${model.tabs.length} left',
      sensitivity: LogSensitivity.sensitive,
    );
    if (result.tabs.isEmpty) {
      // A site always has a tab to show. Closing the last one lands it back on
      // its home page rather than leaving the site blank. Through the same
      // switch as every other re-bind, so a site holding a webview for the tab
      // that was just closed cannot be left rendering it; there is nothing to
      // capture, since that tab is gone.
      final home = SiteTab.primary(url: model.initUrl);
      model.tabs = [home];
      await switchActiveTab(model, home.id, captureOutgoing: false);
      return;
    }
    final next = result.nextActiveId;
    if (result.activeChanged && next != null) {
      if (index == _sites.current || _sites.loaded.contains(index)) {
        await switchActiveTab(model, next, captureOutgoing: false);
        return;
      }
      model.activeTabId = next;
    }
    if (!_host.mounted) return;
    _host.rebuild();
    await _host.commitSites(const SitesEdited());
  }

  Future<void> closeTab(int index, String tabId, {bool subtree = false}) async {
    await _gate.run(() async {
      if (index < 0 || index >= _sites.models.length) return;
      final model = _sites.models[index];
      final result = subtree
          ? TabLifecycleEngine.closeSubtree(model.tabs, model.activeTabId, tabId)
          : TabLifecycleEngine.closeTab(model.tabs, model.activeTabId, tabId);
      await _applyTabClose(index, model, result);
    });
  }

  /// A tab and its subtree dragged to another place in its site's tree
  /// (TAB-015). Only the tree changes: no webview, host or state key does.
  bool moveTab(int index, String tabId, TabDrop drop) {
    if (_gate.busy || !enabledAt(index)) return false;
    final model = _sites.models[index];
    final moved = TabLifecycleEngine.drop(model.tabs, tabId, drop);
    if (moved == null) return false;
    model.tabs = moved;
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
    if (!enabledAt(_sites.current) || _gate.busy) return false;
    final model = _sites.models[_sites.current!];
    final back = wayBackFrom(model);
    if (back == null) return false;
    final index = _sites.models.indexWhere((m) => m.siteId == back.fromSiteId);
    if (index < 0 ||
        !_sites.models[index].tabs.any((t) => t.id == back.fromTabId)) {
      // Where the jump came from is gone, so the gesture does what it would
      // have done without one.
      _returns = const [];
      return false;
    }
    LogService.instance.log(
      'Navigation',
      'Back gesture: at the start of a tab opened from the Tabs sheet; '
          'back where it was opened from',
    );
    await openTab(index, back.fromTabId);
    return true;
  }

  /// A back gesture that ran out of page history. Returns true when it was
  /// spent closing a tab the user had opened from another one, which is what a
  /// browser does with a tab opened from a link (TAB-007). A root tab falls
  /// through to NAV-001 and whatever the NAV-009 setting says.
  Future<bool> _closeChildTabOnBack() async {
    if (!enabledAt(_sites.current)) return false;
    // A close already running owns the tab list; reporting the gesture as
    // spent here would swallow it for nothing.
    if (_gate.busy) return false;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return false;
    }
    final index = _sites.current!;
    final model = _sites.models[index];
    if (TabLifecycleEngine.backAtHistoryStart(model.tabs, model.activeTabId) !=
        TabBackAction.closeAndActivateParent) {
      return false;
    }
    LogService.instance.log(
      'Navigation',
      'Back gesture: at history start in a tab opened from another; closing it',
    );
    await closeTab(index, model.activeTabId);
    return true;
  }
}
