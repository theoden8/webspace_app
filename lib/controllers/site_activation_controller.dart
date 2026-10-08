import 'dart:async';

import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_teardown_engine.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

/// What activation asks of the page's other controllers.
abstract interface class ActivationHost {
  /// Another site by any way leaves the Tabs sheet's way back behind
  /// (TAB-019).
  void forgetTabReturns();

  void enterFullscreen();
  void exitFullscreen();

  Future<void> refreshRoutes({int? activeIndex});
  void syncTorExitPin(Set<int> indices);

  /// Probes [model]'s renderer and recovers a dead or blank one.
  Future<void> probeRenderer(WebViewModel model, {required String trigger});

  /// The loaded sites changed: the background refresh schedule and the iOS
  /// audio session follow.
  void backgroundSitesChanged();
}

/// Which site is on screen, and what moves with it: the site coming on is
/// restored, isolated and resumed, the one leaving is quiesced, and the
/// loaded sites are trimmed to the ones that may stay.
class SiteActivationController {
  SiteActivationController(
    this._sites, {
    required ActivationHost host,
    required ResidencyHost residency,
    required WebViewStateStorage navStates,
    required ContainerIsolationEngine containers,
    required SurfaceRepaintController surface,
  })  : _host = host,
        _residency = residency,
        _navStates = navStates,
        _containers = containers,
        _surface = surface;

  final SiteRuntime _sites;
  final ActivationHost _host;
  final ResidencyHost _residency;
  final WebViewStateStorage _navStates;
  final ContainerIsolationEngine _containers;
  final SurfaceRepaintController _surface;

  /// Set the current index and mark it as loaded for lazy webview creation.
  /// This ensures only visited webviews are created, not all webviews at once.
  /// Also handles domain conflict detection for per-site cookie isolation.
  Future<void> setCurrentIndex(int? index) async {
    final version = ++_sites.activationVersion;
    // Another site by any way leaves the Tabs sheet's way back behind
    // (TAB-019); a jump the sheet makes puts its own back once it lands.
    if (index != _sites.current) _host.forgetTabReturns();

    if (index == null || index < 0 || index >= _sites.models.length) {
      final leaving = _sites.current != null &&
              _sites.current! < _sites.models.length &&
              _sites.loaded.contains(_sites.current)
          ? _sites.models[_sites.current!]
          : null;
      // Going home is committed before the teardown below, never after it
      // (NAV-010): every step there is a native round-trip that can throw,
      // be superseded, or never answer at all, and each of those would
      // abandon the whole call with `_sites.current` still on the site the
      // user asked to leave — a "back to webspaces" that silently did
      // nothing. Nothing in the teardown decides where we end up.
      _sites.current = index;
      _host.exitFullscreen();
      // Opportunistically capture state for the previously-active site so a
      // later cold start (or OS-killed-while-backgrounded scenario) can
      // re-hydrate its back/forward stack and form data on re-activation.
      // The webview stays loaded (pause-only, not disposed) so a
      // near-immediate return to the same site keeps its in-memory tab.
      // Bytes-only capture — `lifecycleState` stays `live` because the
      // webview is not actually disposed.
      if (leaving != null) {
        await _quiesceOutgoingSite(leaving, version: version);
      }
      return;
    }

    final target = _sites.models[index];

    LogTag.cookieIsolation.debug(
        'Switching to site $index: "${target.name}" (siteId: ${target.siteId})',
        sensitive: true);
    LogTag.cookieIsolation.debug(
        'Target domain: ${getBaseDomain(target.initUrl)}', sensitive: true);
    LogTag.cookieIsolation.debug('Currently loaded indices: ${_sites.loaded}');

    // Mark this site as activation-in-flight so concurrent OS memory
    // pressure events can't pick it as a victim before _sites.current
    // is updated below — disposing the webview mid-activation would
    // silently wipe its state from under the user.
    _sites.activating = index;
    try {

    // Whenever the target is about to be built fresh (not already in
    // `_sites.loaded`), fetch any saved navigation state and hand it to
    // the model so the soon-to-be-built controller's onControllerCreated
    // handler can apply restoreState. This covers both in-session
    // re-activation of a `savedForRestore` site AND a cold start, where
    // every site loads from JSON at the default `resident` tier yet the
    // bytes persisted on the previous run (on navigation / backgrounding)
    // still sit on disk — that's the cross-restart back/forward restore.
    //
    // Skipped when the webview is already loaded (rebuild won't recreate
    // the controller, so a queued restore would be stale) and for sites
    // that never persist nav state — incognito (ephemeral) and
    // archive-tier (ARCH-006: state lives only in the slot ciphertext).
    if (!_sites.loaded.contains(index) && target.activeTabPersistsNavState) {
      final bytes = await _navStates.loadState(target.activeStateKey);
      if (version != _sites.activationVersion) return;
      if (bytes != null) {
        target.schedulePendingRestoreState(bytes);
        LogTag.webViewState.debug(
            'Queued ${bytes.length} restore bytes for "${target.name}" '
            '(siteId: ${target.siteId})', sensitive: true);
      }
    }
    // The about-to-be-resumed webview is back at the lowest tier; reset
    // regardless of how it got here (savedForRestore dispose, cacheCleared
    // promotion, or a fresh cold-start load).
    if (target.lifecycleState != SiteLifecycleState.resident) {
      target.lifecycleState = SiteLifecycleState.resident;
    }

    // The loaded sites the target pushes out and the residents that drop
    // their cache. Every rule and its order is SiteUnloadEngine.plan's.
    if (!await applyResidency(residencyPlan(Activating(index)),
        isStale: () => version != _sites.activationVersion)) {
      return;
    }

    // Repoint the shared-profile route before this site can issue a
    // request, not after: the identity is shared, so until this lands the
    // relay still holds the previous shared-profile site's upstream.
    if (_residency.proxyTopology case RoutedProxy(:final sharesDefaultSession)
        when index >= 0 &&
            index < _sites.models.length &&
            sharesDefaultSession(_sites.models[index])) {
      await _host.refreshRoutes(activeIndex: index);
      if (version != _sites.activationVersion) return;
    }

    // Only once the disagreeing siblings are gone: SETCONF takes effect for
    // the whole runtime the moment it lands, so applying it first would
    // route their next request through the new country. Not awaited: the
    // target, if it uses Tor, is held behind the interstitial until the pin
    // lands, and a target that does not use Tor has no reason to wait on tor
    // at all.
    if (TorService.instance.isAvailable) {
      _host.syncTorExitPin(<int>{index, ..._sites.loaded});
    }

    // Pause the previously active webview to save resources. Nothing to do
    // when the user tapped the site they are already on — see the engine.
    final outgoing = SiteActivationEngine.outgoingSiteToQuiesce(
      currentIndex: _sites.current,
      targetIndex: index,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loaded,
    );
    if (outgoing != null) {
      await _quiesceOutgoingSite(_sites.models[outgoing], version: version,
          captureState: false);
      if (version != _sites.activationVersion) return;
    }

    if (_sites.useContainers) {
      // Container path: ensure the named container is recorded.
      // Materialization happens lazily on the native side when the
      // WebView binds via `InAppWebViewSettings.containerId`.
      await _containers.ensureContainer(target.siteId);
      if (version != _sites.activationVersion) return;
    } else {
      await _restoreCookiesForSite(index);
      if (version != _sites.activationVersion) return;
    }

    // Validate index is still in bounds after async gaps
    if (index >= _sites.models.length) return;

    // Decrypt this site's cached/imported HTML into memory before it enters
    // _sites.loaded, so the build's synchronous getHtmlSync hits. Idempotent
    // no-op for sites that have no cached/imported HTML, e.g. a plain URL site.
    await ensureSiteHtml(index);
    if (version != _sites.activationVersion) return;

    _sites.current = index;
    // Bump to end of insertion order so iteration over _sites.loaded is
    // least-recently-used first (consumed by the LRU eviction above).
    _sites.loaded.remove(index);
    _sites.loaded.add(index);

    await _sites.models[index].resumeWebView();

    // A site that sat offscreen while the OS reclaimed memory can come back
    // with a dead renderer (iOS content-process jettison whose termination
    // delegate never fired) or a blank surface (Android hybrid-composition).
    // Probe and recover so a shortcut tap or tab switch doesn't land on a
    // black/blank page. See PAUSE-013.
    unawaited(_host.probeRenderer(target, trigger: 'site-switch'));

    // Defensive sweep: pause every other loaded webview so background
    // sites don't run animations / GPS listeners / non-throttled
    // raf callbacks when the user isn't looking at them. Steady state
    // already has them paused (each becomes paused when it last lost
    // active status above), but a path that adds to _sites.loaded
    // without going through the previous-active pause would leave
    // it unpaused. pauseWebView() is idempotent.
    //
    // unawaited: subsequent activation logic (fullscreen, logging)
    // doesn't depend on these completing, and a page whose JS thread is
    // frozen may never answer at all. Race-wise the version guard inside
    // the teardown is what keeps a sweep still in flight from pausing the
    // site a newer activation has since resumed.
    //
    // (Per-instance pause() doesn't stop JavaScript — see
    // openspec/specs/webview-pause-lifecycle/spec.md. This is a
    // CPU/battery optimization, not RAM. The LRU cap and OS memory
    // pressure handler cover RAM.)
    final loadedSnapshot = _sites.loaded.toList();
    for (final i in loadedSnapshot) {
      if (i == index) continue;
      if (i < 0 || i >= _sites.models.length) continue;
      // Camera stop is dispatched before the pause (CAM-012) and covers the
      // sites pauseWebView() exempts — a notification or background-audio
      // site keeps its JS running, which is exactly where a forgotten capture
      // would survive. Bound to a local model: the steps run a microtask
      // later, by which point _sites.models may have been reindexed.
      final model = _sites.models[i];
      unawaited(
          _quiesceOutgoingSite(model, version: version, captureState: false));
    }

    if (target.fullscreenMode) {
      _host.enterFullscreen();
    } else {
      _host.exitFullscreen();
    }

    LogTag.cookieIsolation.debug(
        'After switch, loaded indices: ${_sites.loaded}', sensitive: true);
    // Force the just-activated Android platform-view surface to recomposite.
    // Bringing a webview onstage (tab tap, shortcut open, cold-start restore)
    // can re-attach the hybrid-composition SurfaceView blank: the page is alive
    // (JS runs, DOM serializes) but nothing paints and the native overscroll
    // gesture is dead, so pull-to-refresh can't recover it — only this relayout
    // can. _probeRendererAndRecover above only relayouts web content, not the
    // surface (see its doc), so it does not cover this. No-op off Android.
    //
    // Activating a site whose document is still in flight has the PAUSE-021
    // ordering on top of that: this nudge drains against a surface that has
    // nothing to show yet, and the commit lands afterwards. Latch it so
    // onLoadSettled repaints the committed document (PAUSE-025).
    if (target.isLoading) _surface.armCommitLatch();
    _surface.nudge('activate');
    // _sites.loaded may have changed (LRU eviction, conflict unload,
    // first-load of target), so re-evaluate the background refresh
    // schedule, and the iOS audio session: the first load of a
    // background-audio site must activate `.playback` before the user starts
    // playback in it. No-op on non-iOS / non-Android.
    _host.backgroundSitesChanged();
    } finally {
      // Clear the in-flight marker only if we still own it; a newer
      // setCurrentIndex caller will have already overwritten it with
      // its own target.
      if (_sites.activating == index) {
        _sites.activating = null;
      }
    }
  }

  /// Unloads the site at [index] (PAUSE-007, ISO-002); see
  /// [SiteUnloadEngine.unload].
  Future<void> unload(int index, {required UnloadReason reason}) =>
      SiteUnloadEngine.unload(_residency,
          index: index, reason: reason);

  ResidencyPlan residencyPlan(ResidencyEvent event) =>
      SiteUnloadEngine.plan(_residency, event: event);

  /// False when [isStale] turned true partway; see [SiteUnloadEngine.apply].
  Future<bool> applyResidency(
    ResidencyPlan plan, {
    required bool Function() isStale,
  }) =>
      SiteUnloadEngine.apply(_residency,
          plan: plan, isStale: isStale);

  /// Capture [model]'s navigation state to encrypted on-disk storage.
  /// Returns true if bytes were captured and persisted. No-op for
  /// incognito sites or when there's nothing to save.
  ///
  /// Does NOT mutate `model.lifecycleState` — callers that are
  /// disposing the webview should do that themselves (typically
  /// flipping to [SiteLifecycleState.savedForRestore]); callers that
  /// are *only* opportunistically persisting (go-home,
  /// app-background) should leave the state at [SiteLifecycleState.resident]
  /// since the webview is still in memory.
  Future<bool> captureStateBytes(WebViewModel model) async {
    // Archive-tier (ARCH-006) and incognito sites never persist nav state,
    // and a hosted tab only when its host would keep it (LIR-022).
    if (!model.activeTabPersistsNavState) return false;
    // The key is the one the bytes belong to, read before the capture: a tab
    // switch or a container flip (LIR-034) landing while it runs would make
    // the key read afterwards name another tab or another identity, and these
    // bytes would be restored there.
    final tabId = model.activeTabId;
    final key = model.activeStateKey;
    final bytes = await model.captureNavigationState();
    if (bytes == null) return false;
    if (model.activeTabId != tabId || model.activeStateKey != key) {
      LogTag.webViewState.debug(
          'Dropped a capture for "${model.name}": its tab changed meanwhile',
          sensitive: true);
      return false;
    }
    await _navStates.saveState(key, state: bytes);
    LogTag.webViewState.debug(
        'Captured ${bytes.length} bytes for "${model.name}" '
        '(state key: $key)', sensitive: true);
    return true;
  }

  /// Quiesce the site the user is leaving — a site switch, or a return to the
  /// webspace list (which also captures nav state).
  ///
  /// Ordering is CAM-012 / BGAUDIO-009: on iOS the per-instance pause blocks
  /// the page's JS thread, so the camera stop and the media pause have to be
  /// dispatched before it or they sit queued behind it forever. That same
  /// freeze is why the engine bounds the sequence — a page an earlier pause
  /// left frozen never answers `evaluateJavascript` again, and the caller's
  /// own state change must not hang on it (NAV-010).
  Future<void> _quiesceOutgoingSite(
    WebViewModel model, {
    required int version,
    bool captureState = true,
  }) async {
    final result = await SiteTeardownEngine.quiesceOutgoing(
      superseded: () => version != _sites.activationVersion,
      steps: [
        if (captureState)
          SiteTeardownStep('captureState',
              run: () => captureStateBytes(model)),
        SiteTeardownStep('stopRealCapture', run: model.stopRealCapture),
        SiteTeardownStep('pauseMediaPlayback', run: model.pauseMediaPlayback),
        SiteTeardownStep('pauseWebView', run: model.pauseWebView),
      ],
    );
    if (result.isClean) return;
    LogService.instance.log(
      LogTag.webView,
      message: 'Teardown of "${model.name}" ran ${result.ran}'
          '${result.errors.isEmpty ? '' : ', failed ${result.errors}'}'
          '${result.stalledOn == null ? '' : ', stalled on ${result.stalledOn}'}'
          '${result.supersededBefore == null ? '' : ', superseded before ${result.supersededBefore}'}',
      level: result.stalledOn == null ? LogLevel.info : LogLevel.warning,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// Capture state and flip the lifecycle to [SiteLifecycleState.savedForRestore].
  /// Used by dispose paths (LRU eviction, memory-pressure cascade,
  /// legacy webspace-switch unload) where the webview is about to be
  /// torn down.
  Future<void> captureStateForRestore(WebViewModel model) async {
    final ok = await captureStateBytes(model);
    if (ok) {
      model.lifecycleState = SiteLifecycleState.savedForRestore;
    }
  }

  /// Restores cookies for a site before activation.
  Future<void> _restoreCookiesForSite(int index) async {
    final version = _sites.activationVersion;
    await _residency.sharedJar!.restoreCookiesForSite(
      index: index,
      models: _sites.models,
      loadedIndices: _sites.loaded,
      versionAtEntry: version,
      currentVersion: () => _sites.activationVersion,
    );
  }

  /// Decrypt the cached/imported HTML for one site into memory before its
  /// webview builds, so the build's synchronous `getHtmlSync` hits. Uses the
  /// same [htmlSourceFor] classification as the build's `initialHtml` read, so
  /// the preload can never target a different store than the read (a blank
  /// site). Cheap no-op when the site has nothing on disk.
  Future<void> ensureSiteHtml(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    await ensureSiteHtmlForModel(_sites.models[index]);
  }

  /// Model-keyed variant — safe to call across `await`s in deferred loops where
  /// the index may shift (a site added/deleted while it runs), since it doesn't
  /// re-index `_sites.models`.
  Future<void> ensureSiteHtmlForModel(WebViewModel m) async {
    switch (htmlSourceFor(
      incognito: m.incognito,
      isArchiveTier: m.isArchiveTier,
      initUrl: m.initUrl,
    )) {
      case HtmlSource.import:
        await HtmlImportStorage.instance.preloadOne(m.siteId);
      case HtmlSource.cache:
        await HtmlCacheService.instance.preloadOne(m.siteId);
      case HtmlSource.none:
        break;
    }
  }
}
