import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';

/// What the resets ask of the page.
abstract interface class SiteResetHost implements PageHost {
  void enterFullscreen();
  void exitFullscreen();
}

/// The ways a site's webview is rebuilt or sent home: after a settings or
/// script change, by Home, Refresh and Stop, and for the always-home sites a
/// shortcut launch resets.
class SiteResetController {
  SiteResetController(
    this._sites, {
    required SiteResetHost host,
    required TabsController tabs,
    required SiteActivationController activation,
  }) : _host = host,
       _tabs = tabs,
       _activation = activation;

  final SiteRuntime _sites;
  final SiteResetHost _host;
  final TabsController _tabs;
  final SiteActivationController _activation;

  /// Drop the cached HTML snapshot for a site so the next webview rebuild
  /// boots clean — but only when we're (likely) online. When offline the
  /// cached snapshot is the only content we can render, so preserve it
  /// until a live reload can overwrite it (via the `onHtmlLoaded` callback
  /// on the next successful `onLoadStop`).
  ///
  /// Synchronous in-memory eviction. Sync because callers like [goHome]
  /// dispose the webview and trigger a rebuild in the same event-loop turn
  /// — `getHtmlSync(siteId)` runs during that rebuild's build phase, so an
  /// async eviction loses the race and the rebuilt webview boots with the
  /// stale snapshot anyway. The eviction also bumps the
  /// [HtmlCacheService] generation, so any `saveHtml` for the same siteId
  /// already in flight (e.g. the previous snapshot IPC
  /// resolving after dispose) is rejected at write time and cannot
  /// resurrect the stale bytes the call site just dropped.
  ///
  /// Online gate uses [ConnectivityService.lastKnownOnline] (primed at
  /// startup, refreshed by every probe). Treats unknown as online so
  /// post-startup callers get the eviction; the only cost of a wrong
  /// guess offline is losing the cached fallback for one rebuild —
  /// `controller.reload()` is itself online-gated in [WebViewFactory], so
  /// nothing tries to fetch a live page we can't reach.
  ///
  /// Disk file is left alone. The next live `saveHtml` overwrites it; if
  /// the app is killed before that fires, `preloadCache` reads it back at
  /// next launch and the cached-then-live rebuild path heals it on first
  /// webview load. Use [HtmlCacheService.deleteCache] when the disk file
  /// must also go (orphan cleanup, explicit site deletion).
  void evictCacheIfOnline(String siteId) {
    if (ConnectivityService.instance.lastKnownOnline ?? true) {
      HtmlCacheService.instance.evictInMemory(siteId);
    }
  }

  /// Dispose the current site's webview so the next render recreates it
  /// with fresh [initialUserScripts] and [initialSettings]. Used after
  /// the user edits the script list or any per-site setting baked at
  /// webview creation time — UA, language, location/timezone, content
  /// blocker, etc. The native WKUserScript / Android UserScript objects
  /// are immutable post-creation, and so are the platform UA / desktop-
  /// mode flags; `controller.loadUrl` alone reloads the *page* but
  /// reuses those baked-in values, so e.g. a desktop UA set after the
  /// webview was created wouldn't activate the desktop_mode_shim.
  ///
  /// Also drops the cached HTML (online only): the snapshot was captured
  /// with the previous script set applied, so showing it on next load
  /// would render the pre-edit DOM before the new scripts re-run.
  void resetShown() {
    if (_sites.current == null || _sites.current! >= _sites.models.length)
      return;
    evictCacheIfOnline(_sites.models[_sites.current!].siteId);
    _sites.models[_sites.current!].disposeWebView();
    _host.rebuild();
  }

  /// Persist settings, then recreate the current site's webview so the
  /// updated UA / language / location / shim-relevant fields take effect
  /// through fresh `initialSettings` and `initialUserScripts`. Wired into
  /// [SettingsScreen]'s `onSettingsSaved`.
  Future<void> settingsSaved() async {
    await _host.commitSites(const SiteSettingsSaved());
    if (!_host.mounted) return;
    final model = _sites.shown;
    if (model != null && model.fullscreenMode) {
      _host.enterFullscreen();
    } else {
      _host.exitFullscreen();
    }
    if (model != null) {
      resetShown();
    } else {
      _host.rebuild();
    }
  }

  /// Dispose every loaded webview. Used after global user script edits,
  /// which can affect any site that has opted in. Caches for sites that
  /// have any global opt-in are dropped (online only) for the same reason
  /// as [resetShown].
  void resetAll() {
    for (final model in _sites.models) {
      if (model.enabledGlobalScriptIds.isNotEmpty) {
        evictCacheIfOnline(model.siteId);
      }
    }
    for (final model in _sites.models) {
      model.disposeWebView();
    }
    _host.rebuild();
  }

  /// User-driven reload of the current site (Refresh button, Clear-cookies).
  /// Delegates to [WebViewModel.userDrivenReload] which drops the
  /// HtmlCacheService snapshot and the chromium HTTP cache before the
  /// reload, so the user actually gets fresh content instead of being
  /// served the same stale page from disk cache (issue #290).
  Future<void> refreshShown() async {
    if (_sites.current == null || _sites.current! >= _sites.models.length)
      return;
    await _sites.models[_sites.current!].userDrivenReload();
  }

  Future<void> stopShown() async {
    if (_sites.current == null || _sites.current! >= _sites.models.length)
      return;
    await _sites.models[_sites.current!].userStopLoading();
  }

  /// Reset every "Always open Home" / incognito site that shares a named
  /// webspace with [launchedIndex] back to its `initUrl` and tear down its
  /// live webview so the next paint reloads at home. Called from both the
  /// cold and warm shortcut entrypoints — on cold launch most flagged
  /// sites already had `currentUrl` dropped during `fromJson`, so the
  /// pass is mostly a no-op there; on warm launch it is the only thing
  /// that resets siblings.
  ///
  /// A site with tabs is not sent home in place: it lands on a tab at home,
  /// and the tab it was on stays in its list (TAB-014).
  Future<void> resetHomeOnLaunch(int launchedIndex) async {
    final indices = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
      launchedIndex: launchedIndex,
      webspaces: _sites.webspaces,
      flag: (i) {
        if (i < 0 || i >= _sites.models.length) return false;
        final m = _sites.models[i];
        return m.alwaysOpenHome || m.incognito;
      },
    );
    final withTabs = [
      for (final i in indices)
        if (_tabs.enabledAt(i)) _sites.models[i],
    ];
    for (final i in indices) {
      final m = _sites.models[i];
      if (withTabs.contains(m)) continue;
      if (m.currentUrl == m.initUrl && m.webview == null) continue;
      evictCacheIfOnline(m.siteId);
      await _tabs.bindOwnerRunTab(m);
      if (!_host.mounted) return;
      m.currentUrl = m.initUrl;
      // Keep the active site in _sites.loaded (mirrors
      // _resetAlwaysOpenHomeForAppClose / goHome) so the IndexedStack still
      // has a child to rebuild at initUrl. Dropping it black-screens a warm
      // shortcut re-tap of the already-current site: _openShortcutIndex skips
      // setCurrentIndex when index == _sites.current, so nothing would re-add
      // it or recreate the disposed webview.
      if (i == _sites.current) {
        m.disposeWebView();
      } else {
        await _activation.unload(i, reason: UnloadReason.homeReset);
        if (!_host.mounted) return;
      }
    }
    for (final m in withTabs) {
      if (!_host.mounted) return;
      await _tabs.landOnHomeTab(m);
    }
  }

  /// Navigate to the site's initial URL and clear navigation history.
  /// Disposes the webview so it's recreated fresh with no back history.
  /// Evicts the in-memory HTML cache snapshot (online only) so the
  /// rebuilt webview boots clean and goes straight to the live home URL
  /// rather than flashing a stale cached frame. Offline: the cache is
  /// preserved — it's the only content we can render without network.
  void goHome() {
    if (_sites.current == null || _sites.current! >= _sites.models.length)
      return;
    final model = _sites.models[_sites.current!];
    evictCacheIfOnline(model.siteId);
    model.currentUrl = model.navigationHomeUrl;
    model.disposeWebView();
    _host.rebuild();
    // Re-apply fullscreen for sites with auto-fullscreen after webview recreation
    if (model.fullscreenMode) {
      _host.enterFullscreen();
    }
    _host.commitSites(const SitesEdited());
  }
}
