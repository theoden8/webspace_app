import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/services/theme_color_scheme_shim.dart';
import 'package:webspace/services/user_agent_metadata_builder.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/file_import_document.dart';
import 'package:webspace/services/webview.dart';

abstract class WebViewController {
  /// The underlying `inapp.InAppWebViewController` this wrapper is
  /// bound to. Exposed so per-site code paths can pass it as the
  /// `webViewController:` argument to `inapp.CookieManager` methods,
  /// which the WebSpace fork uses to resolve the WebView's bound
  /// container and route cookie ops to its per-container jar.
  inapp.InAppWebViewController get nativeController;

  Future<void> loadUrl(String url, {String? language});
  /// False when no load starts: the webview is gone or the platform refused.
  Future<bool> reload();
  Future<Uri?> getUrl();
  Future<String?> getTitle();
  Future<String?> getHtml();
  Future<void> evaluateJavascript(String source);
  /// Evaluate [source] and return whatever the JS expression produced,
  /// JSON-decoded by the platform plugin into a Dart `dynamic`.
  /// Distinct from
  /// [evaluateJavascript] which suffixes the source with `null;` to
  /// neutralize WebKit's "unsupported return type" errors and so
  /// always resolves to `null`.
  Future<Object?> evaluateJavascriptReturning(String source);
  Future<void> findAllAsync({required String find});
  Future<void> findNext({required bool forward});
  Future<void> clearMatches();
  Future<String?> getDefaultUserAgent();
  Future<void> setOptions({
    required bool javascriptEnabled,
    String? userAgent,
    bool? thirdPartyCookiesEnabled,
    bool? incognito,
  });
  Future<void> setThemePreference(WebViewTheme theme);
  /// Update the page-text zoom (percent, 100 = unscaled). Used to track
  /// system "font size" accessibility changes after the webview is created.
  Future<void> setTextZoom(int zoomPercent);
  Future<void> goBack();
  Future<bool> canGoBack();
  /// Per-instance pause to reduce resource usage.
  ///
  /// On Android: **no-op.** `WebView.onPause()` only does a best-effort pause
  /// of animations and geolocation and **does NOT pause JavaScript** (Android
  /// pauses JS only via the process-global `pauseTimers()`), so per-instance
  /// pause is nearly useless — while cycling the foreground hybrid-composition
  /// SurfaceView through onPause/onResume blanks it on the next paint. JS is
  /// frozen at app-background via [pauseAllJsTimers]; memory pressure disposes.
  ///
  /// On iOS: calls `pauseTimers()`, which the plugin implements per-instance
  /// via an `alert()`-deadlock hack that blocks this WebView's main JS thread.
  ///
  /// Activity that keeps running while paused on **both** platforms:
  ///   - Web Workers and Service Workers
  ///   - network requests already in flight (and any `Set-Cookie` they return)
  ///   - media playback (`<video>` / `<audio>` decoders)
  ///   - WebRTC peer connections, WebSocket frames over the wire
  ///
  /// `pause()` is for resource saving. It is **not a security boundary** — a
  /// page can observe cookies being deleted or proxy being swapped while
  /// paused (e.g. via a Service Worker fetch, or via `document.cookie` diff
  /// on the next `visibilitychange`). To safely mutate global state under
  /// a webview, dispose it instead.
  Future<void> pause();

  Future<void> resume();

  /// Pause JavaScript timers (`setTimeout`/`setInterval`/`requestAnimationFrame`)
  /// process-globally on Android, per-instance on iOS.
  ///
  /// On Android, `WebView.pauseTimers()` is documented as global across all
  /// loaded WebViews. Use this only when the whole app is going to background;
  /// do **not** use it to pause a single site, otherwise you also freeze the
  /// site that's about to become active.
  Future<void> pauseAllJsTimers();

  Future<void> resumeAllJsTimers();

  /// Abort any in-flight main-frame load. Used to quiesce chromium
  /// before queuing a follow-up navigation, shrinking the overlap
  /// between in-flight teardown and the next loadUrl.
  Future<void> stopLoading();

  /// Drop the WebView's in-memory cache (decoded image cache + the
  /// HTTP response cache). Tab state stays — the page keeps running,
  /// the back/forward stack is intact. Idempotent: a second call
  /// is a near no-op (the cache is already empty).
  ///
  /// Used by the [SiteLifecyclePromotionEngine] cacheCleared tier to
  /// reclaim memory under OS pressure without losing tab state. Frees
  /// roughly 10-50 MB per webview depending on what was cached.
  Future<void> clearCache();

  /// Capture the WebView's navigation state into a serializable byte
  /// blob. Pair with [restoreState] on a freshly-created controller
  /// to re-hydrate the back/forward stack and (on iOS 15+ / macOS
  /// 12+) form-field values. Live JS heap and DOM are NOT preserved.
  ///
  /// Returns null when there's nothing to save (e.g. a webview that
  /// never navigated).
  ///
  /// Platform mapping:
  ///   - Android: `WebView.saveState(Bundle)` — back/forward + scroll.
  ///   - iOS 15+ / macOS 12+: `WKWebView.interactionState` — back/
  ///     forward + form-field values + scroll.
  ///   - Linux (WebKitGTK / WPE): `webkit_web_view_get_session_state`
  ///     + `webkit_web_view_session_state_serialize` — back/forward
  ///     + scroll. Form-field values are NOT preserved (Apple-only).
  Future<Uint8List?> saveState();

  /// Apply [state] (previously returned by [saveState] on the same
  /// site) to this controller. Returns true on success.
  Future<bool> restoreState(Uint8List state);
}

/// Which native call the per-instance [WebViewController.pause] /
/// [WebViewController.resume] makes on a given platform (PAUSE-016).
enum PerInstanceLifecycleCall {
  /// No native call. Android (`WebView.onPause()` doesn't freeze JS and
  /// cycling the SurfaceView blanks it — PAUSE-016) and desktop platforms.
  none,

  /// iOS: `pauseTimers()` / `resumeTimers()` — the plugin's per-instance
  /// `alert()`-deadlock hack, the only per-site JS-freeze lever on iOS.
  timers,
}

/// Pure platform dispatch for per-instance pause/resume. Extracted so the
/// PAUSE-016 Android no-op is unit-testable without a native controller.
PerInstanceLifecycleCall perInstanceLifecycleCallFor({
  required bool isAndroid,
  required bool isIOS,
}) {
  if (isAndroid) return PerInstanceLifecycleCall.none;
  if (isIOS) return PerInstanceLifecycleCall.timers;
  return PerInstanceLifecycleCall.none;
}

/// Whether `pauseTimers()` on this platform is the plugin's messageless
/// `alert()` hack rather than a real timer pause. Android has the real API
/// (`WebView.pauseTimers()`); iOS and macOS both implement it by evaluating
/// `alert()` and having the native `WKUIDelegate` withhold its dismissal
/// callback, which is what blocks the page's JS thread.
bool pauseTimersUsesAlertHack({
  required bool isAndroid,
  required bool isIOS,
  required bool isMacOS,
}) =>
    !isAndroid && (isIOS || isMacOS);

/// Per-webview record of whether the `alert()`-hack pause has ever run on it
/// (PAUSE-030), so the hack's own alert can be told apart from a dialog the
/// page asked for.
class PauseTimersHackState {
  bool _issued = false;

  /// True once a `pauseTimers()` that uses the alert hack has been issued on
  /// this webview. Sticky: the hack leaves an alert queued in the page's JS
  /// event loop with no signal for when it was consumed, so there is no point
  /// at which this can be cleared without re-opening the escape.
  bool get pauseWasIssued => _issued;

  void notePauseIssued() => _issued = true;
}

/// Whether a JS alert arriving in Dart is the escaped remains of the
/// `alert()`-hack pause (PAUSE-030) rather than a dialog the page asked for.
///
/// `pauseTimers()` marks the webview paused and evaluates `alert()`; the
/// native delegate swallows that alert for as long as the mark is set.
/// `resumeTimers()` clears the mark on the next site switch, app resume or
/// dispose whether or not the alert has been delivered — and
/// `evaluateJavaScript` queues behind the page's own JS, so on a busy or
/// still-loading page the alert can land after the mark is gone and fall
/// through to the app as a real, messageless system dialog.
///
/// Only an escaped alert can reach this predicate: the native delegate
/// consults Dart only after its own paused check, so while the pause is live
/// the alert never gets here. Answering it therefore releases a JS thread
/// whose pause is already over, rather than cutting one short.
///
/// A page's own main-frame `alert('')` on an already-paused webview is
/// swallowed too. It is indistinguishable from the hack's, and it renders as
/// an empty system dialog carrying no information either way.
bool isEscapedPauseTimersAlert({
  required bool pauseWasIssued,
  required String? message,
  required bool? isMainFrame,
}) =>
    pauseWasIssued && (message ?? '').isEmpty && (isMainFrame ?? true);

/// Writes the fields [WebViewController.setOptions] owns onto the settings a
/// webview was created with; every other field keeps its value.
@visibleForTesting
void applyWebViewOptions(
  inapp.InAppWebViewSettings settings, {
  required bool javascriptEnabled,
  String? userAgent,
  bool? thirdPartyCookiesEnabled,
  bool? incognito,
}) {
  settings
    ..javaScriptEnabled = javascriptEnabled
    ..userAgent = userAgent
    // Keep Sec-CH-UA*/navigator.userAgentData consistent with the UA
    // string. Webview recreation on UA edits is the primary path
    // (DM-001), so this is a defensive parallel apply for the rare
    // setSettings-only path.
    ..userAgentMetadata = buildUserAgentMetadata(userAgent)
    ..thirdPartyCookiesEnabled = thirdPartyCookiesEnabled ?? false
    ..incognito = incognito ?? false;
}

/// The [WebViewController] over one native webview. Every native call goes
/// through [_native], so a call on a webview that has left the tree is a
/// no-op and a platform refusal reads as "nothing happened".
class PlatformWebViewController implements WebViewController {
  final inapp.InAppWebViewController _c;

  /// Set by [ControllerScope] in the frame the plugin disposes [_c]. A call
  /// on a disposed controller asserts in debug and does nothing in release.
  bool _disposed = false;

  /// The webview left the tree; every call after this is a no-op.
  void markDisposed() => _disposed = true;

  /// Shared with the `onJsAlert` handler of the same webview, which needs to
  /// know that this controller issued an alert-hack pause (PAUSE-030).
  final PauseTimersHackState _pauseHack;

  final FileImportDocument? _import;

  /// The settings this webview was created with, kept current by every
  /// update. Each `setSettings` sends this whole object: the plugin sends
  /// every field of what it is given, Android and iOS/macOS apply each one
  /// that differs, and Linux replaces its settings wholesale, so a fresh
  /// object resets whatever it leaves out to the plugin default (BUG-022).
  final inapp.InAppWebViewSettings _settings;

  PlatformWebViewController(
    this._c, {
    required PauseTimersHackState pauseHack,
    required inapp.InAppWebViewSettings settings,
    FileImportDocument? fileImport,
  })  : _pauseHack = pauseHack,
        _settings = settings,
        _import = fileImport;

  /// Null when the webview is gone or the platform refused: a native
  /// failure arrives as [PlatformException], a torn-down platform view as
  /// [MissingPluginException], and a method the platform's plugin lacks
  /// (Linux WPE has no `getDefaultUserAgent`) as [UnimplementedError] from
  /// the platform interface.
  Future<T?> _native<T>(Future<T?> Function() call) async {
    if (_disposed) return null;
    try {
      return await call();
    } on PlatformException catch (e) {
      LogTag.webView.debug('Native call refused: $e', sensitive: true);
      return null;
    } on MissingPluginException {
      return null;
    } on UnimplementedError {
      return null;
    }
  }

  Future<bool> _issued(Future<void> Function() call) async =>
      await _native(() => call().then((_) => true)) ?? false;

  @override
  inapp.InAppWebViewController get nativeController => _c;

  @override
  Future<void> loadUrl(String url, {String? language}) async {
    final fileImport = _import;
    if (fileImport != null && fileImport.isLoadOf(url)) {
      await _loadHtml(fileImport.html, baseUrl: fileImport.url);
      return;
    }
    final headers = <String, String>{};
    // HTTP headers are only meaningful for http(s) schemes. Attaching them to
    // non-HTTP URLs (chrome://, about:, file://, data:, javascript:) routes
    // the request through the WebView's HTTP path and can get rejected as
    // "invalid URL".
    final isHttp = url.startsWith('http://') || url.startsWith('https://');
    if (isHttp) {
      headers['DNT'] = '1';
      headers['Sec-GPC'] = '1';
    }
    if (language != null && isHttp) {
      headers['Accept-Language'] = '$language, *;q=0.5';
    }
    await _native(() => _c.loadUrl(
          urlRequest: inapp.URLRequest(
            url: inapp.WebUri(url),
            headers: headers.isNotEmpty ? headers : null,
          ),
        ));
  }

  Future<bool> _loadHtml(String html, {required String baseUrl}) =>
      _issued(() => _c.loadData(
            data: html,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: inapp.WebUri(baseUrl),
          ));

  @override
  Future<bool> reload() {
    final fileImport = _import;
    if (fileImport != null &&
        FileImportDocument.rendersOnReload(isAndroid: hostIsAndroid)) {
      return _loadHtml(fileImport.html, baseUrl: fileImport.url);
    }
    return _issued(() => _c.reload());
  }

  @override
  Future<Uri?> getUrl() => _native(_c.getUrl);

  @override
  Future<String?> getTitle() async => await _native(_c.getTitle);

  @override
  Future<String?> getHtml() async => await _native(_c.getHtml);

  @override
  Future<void> evaluateJavascript(String source) =>
      _native(() => _c.evaluateJavascript(source: '$source\n;null;'));

  @override
  Future<Object?> evaluateJavascriptReturning(String source) =>
      _native(() => _c.evaluateJavascript(source: source));

  @override
  Future<void> findAllAsync({required String find}) =>
      _native(() => _c.findAllAsync(find: find));

  @override
  Future<void> findNext({required bool forward}) =>
      _native(() => _c.findNext(forward: forward));

  @override
  Future<void> clearMatches() => _native(_c.clearMatches);

  @override
  Future<String?> getDefaultUserAgent() async =>
      await _native(inapp.InAppWebViewController.getDefaultUserAgent);

  @override
  Future<void> setOptions({
    required bool javascriptEnabled,
    String? userAgent,
    bool? thirdPartyCookiesEnabled,
    bool? incognito,
  }) {
    applyWebViewOptions(
      _settings,
      javascriptEnabled: javascriptEnabled,
      userAgent: userAgent,
      thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
      incognito: incognito,
    );
    // The OS text size can change between creation and this call, before
    // didChangeTextScaleFactor can reach the controller.
    _settings.textZoom = WebViewFactory.systemTextZoomPercent();
    return _native(() => _c.setSettings(settings: _settings));
  }

  @override
  Future<void> setThemePreference(WebViewTheme theme) async {
    final themeValue = theme == WebViewTheme.system ? 'system' : (theme == WebViewTheme.dark ? 'dark' : 'light');
    // Rotate the DOCUMENT_START user script so future page loads
    // (including controller.reload()) re-run the shim. Without this,
    // a refresh drops the matchMedia override and `<meta name=
    // "color-scheme">` and the page falls back to its own default
    // (typically light), since onUrlChanged dedups same-URL events
    // and skips its own evaluateJavascript reapplication.
    await _rotateShim(
        'theme_color_scheme_shim', shim: buildThemeColorSchemeShim(themeValue));
  }

  @override
  Future<void> setTextZoom(int zoomPercent) async {
    if (hostIsAndroid) {
      _settings.textZoom = zoomPercent;
      await _native(() => _c.setSettings(settings: _settings));
      return;
    }
    // iOS/macOS: WKWebView has no textZoom setting. Rotate the
    // DOCUMENT_START user script so future page loads pick up the new
    // value, then update the style element on the current page.
    await _rotateShim('system_text_zoom', shim: buildTextZoomShim(zoomPercent));
  }

  Future<void> _rotateShim(String group, {required String shim}) async {
    await _native(() => _c.removeUserScriptsByGroupName(groupName: group));
    await _native(() => _c.addUserScript(
        userScript: pageShim(group, js: shim, frames: ShimFrames.all)));
    await evaluateJavascript(shim);
  }

  @override
  Future<void> goBack() => _native(_c.goBack);

  @override
  Future<bool> canGoBack() async => await _native(_c.canGoBack) ?? false;

  @override
  Future<void> pause() async {
    // PAUSE-016: Android is a no-op. `WebView.onPause()` doesn't pause JS (only
    // the process-global `pauseTimers()` does), so per-instance pause buys
    // nothing for the JS-freeze goal — yet cycling the foreground hybrid-
    // composition SurfaceView through onPause/onResume leaves it blank on the
    // next paint (the white-screen bug). App-lifecycle backgrounding freezes JS
    // via the global `pauseAllJsTimers()`; memory pressure disposes.
    switch (perInstanceLifecycleCallFor(
        isAndroid: hostIsAndroid, isIOS: hostIsIOS)) {
      case PerInstanceLifecycleCall.none:
        return;
      case PerInstanceLifecycleCall.timers:
        _pauseHack.notePauseIssued();
        await _native(_c.pauseTimers);
    }
  }

  @override
  Future<void> resume() async {
    // Mirror of [pause] (PAUSE-016): no-op on Android.
    switch (perInstanceLifecycleCallFor(
        isAndroid: hostIsAndroid, isIOS: hostIsIOS)) {
      case PerInstanceLifecycleCall.none:
        return;
      case PerInstanceLifecycleCall.timers:
        await _native(_c.resumeTimers);
    }
  }

  @override
  Future<void> pauseAllJsTimers() {
    // On iOS and macOS there is no process-global lever: this lands on the
    // same per-instance alert hack as [pause] and leaves the same escapable
    // alert behind (PAUSE-030).
    if (pauseTimersUsesAlertHack(
        isAndroid: hostIsAndroid, isIOS: hostIsIOS, isMacOS: hostIsMacOS)) {
      _pauseHack.notePauseIssued();
    }
    return _native(_c.pauseTimers);
  }

  @override
  Future<void> resumeAllJsTimers() => _native(_c.resumeTimers);

  @override
  Future<void> stopLoading() => _native(_c.stopLoading);

  @override
  Future<void> clearCache() => _native(_c.clearCache);

  @override
  Future<Uint8List?> saveState() async => await _native(_c.saveState);

  @override
  Future<bool> restoreState(Uint8List state) async =>
      await _native(() => _c.restoreState(state)) ?? false;
}

/// Marks the [PlatformWebViewController] of the webview under it disposed when that
/// webview leaves the tree, the frame the plugin disposes the native
/// controller. Sits directly over the `InAppWebView` and carries its key, so
/// the two elements live and die together.
class ControllerScope extends StatefulWidget {
  const ControllerScope({
    super.key,
    required this.onUnmount,
    required this.child,
  });

  final VoidCallback onUnmount;
  final Widget child;

  @override
  State<ControllerScope> createState() => _ControllerScopeState();
}

class _ControllerScopeState extends State<ControllerScope> {
  // The plugin keeps answering through the callbacks of the widget that
  // created the native view, so a later widget's callback never names it.
  late final VoidCallback _onUnmount;

  @override
  void initState() {
    super.initState();
    _onUnmount = widget.onUnmount;
  }

  @override
  void dispose() {
    _onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
