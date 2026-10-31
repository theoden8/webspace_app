import 'dart:async';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';

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

  /// Dispose the current site's webview so the next render recreates it
  /// with fresh [initialUserScripts] and [initialSettings]. Used after
  /// the user edits the script list or any per-site setting baked at
  /// webview creation time — UA, language, location/timezone, content
  /// blocker, etc. The native WKUserScript / Android UserScript objects
  /// are immutable post-creation, and so are the platform UA / desktop-
  /// mode flags; `controller.loadUrl` alone reloads the *page* but
  /// reuses those baked-in values, so e.g. a desktop UA set after the
  /// webview was created wouldn't activate the desktop_mode_shim.
  void resetShown() {
    if (_sites.current == null || _sites.current! >= _sites.models.length)
      return;
    _sites.models[_sites.current!].disposeWebView(commit: const Commit.environment(Environment.letGo));
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
  /// which can affect any site that has opted in.
  void resetAll() {
    for (final model in _sites.models) {
      model.disposeWebView(commit: const Commit.environment(Environment.letGo));
    }
    _host.rebuild();
  }

  /// User-driven reload of the current site (Refresh button, Clear-cookies).
  /// Delegates to [WebViewModel.userDrivenReload], which drops the engine's
  /// HTTP cache before the reload while online, so the user gets fresh
  /// content instead of the same page from disk cache (issue #290).
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
  Future<void> resetHomeOnLaunch(WebViewModel launched) async {
    final launchedIndex = _sites.models.indexOf(launched);
    if (launchedIndex < 0) return;
    final indices = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
      launchedIndex: launchedIndex,
      webspaces: _sites.webspaces,
      flag: (i) {
        if (i < 0 || i >= _sites.models.length) return false;
        final m = _sites.models[i];
        return m.alwaysOpenHome || m.incognito;
      },
    );
    // Sites, not rows: the loop awaits, and a row can name another site
    // after an await.
    final sites = [for (final i in indices) _sites.models[i]];
    final withTabs = [
      for (final m in sites)
        if (_tabs.enabledFor(m)) m,
    ];
    for (final m in sites) {
      if (withTabs.contains(m)) continue;
      if (m.currentUrl == m.initUrl && m.webview == null) continue;
      await _tabs.bindOwnerRunTab(m);
      if (!_host.mounted) return;
      m.currentUrl = m.initUrl;
      await _activation.unload(m, reason: UnloadReason.homeReset);
      if (!_host.mounted) return;
    }
    for (final m in withTabs) {
      if (!_host.mounted) return;
      await _tabs.landOnHomeTab(m);
    }
  }

  /// Navigate to the site's initial URL and clear navigation history.
  /// Disposes the webview so it's recreated fresh with no back history.
  void goHome() {
    if (_sites.current == null || _sites.current! >= _sites.models.length)
      return;
    final model = _sites.models[_sites.current!];
    model.currentUrl = model.navigationHomeUrl;
    model.disposeWebView(commit: const Commit.environment(Environment.letGo));
    _host.rebuild();
    // Re-apply fullscreen for sites with auto-fullscreen after webview recreation
    if (model.fullscreenMode) {
      _host.enterFullscreen();
    }
    unawaited(_host.commitSites(const SitesEdited()));
  }
}
