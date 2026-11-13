import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/screen_share.dart';
import 'package:webspace/web_view_model.dart';

/// How a site's webview is paused and resumed: as it leaves the screen, as
/// the app goes to the background, and what each leaves running (PAUSE-*).
extension WebViewModelPause on WebViewModel {
  /// Per-instance pause for site switches.
  ///
  /// Reduces resource usage but does NOT fully stop the page — Web Workers,
  /// Service Workers, in-flight network requests (and the `Set-Cookie` they
  /// return), media playback, WebRTC and WebSocket I/O all keep running. On
  /// Android, JS timers also keep running (Android's per-instance pause does
  /// not cover them, and the global timer pause would freeze other tabs too).
  /// This is a resource hint, not a security boundary — see
  /// [WebViewController.pause] for the full caveat list. To safely mutate
  /// cookies or proxy under a webview, dispose it instead.
  ///
  /// Skipped for sites with [notificationsEnabled] set: on iOS, per-instance
  /// pause is implemented via `pauseTimers()` (the plugin's alert-deadlock
  /// hack), which freezes this WebView's JS thread. That stalls any
  /// setInterval / setTimeout / WebSocket-driven notification poller until
  /// the user switches back, at which point all queued notifications fire
  /// at once. Sites the user enabled notifications on must keep running.
  ///
  /// Also skipped for sites with [backgroundAudioEnabled] (BGAUDIO-001): the
  /// same iOS alert-hack freeze would stall a streaming player's JS the
  /// moment the user switches to another site, cutting the audio the toggle
  /// exists to keep playing.
  Future<void> pauseWebView() async {
    if (controller == null) return;
    if (notificationsEnabled) return;
    if (effectiveBackgroundAudioEnabled) return;
    await controller!.pause();
    LogTag.webView.debug(
        'Paused webview for "$name" (siteId: $siteId)', sensitive: true);
  }

  /// End any device capture this site is running: camera (CAM-012) and
  /// microphone (MIC-012), through one hook over the shims' shared registry,
  /// and a share of the screen (SHARE-017), which Android runs for the app
  /// rather than the page, so it ends here whatever the page does.
  ///
  /// Called when the site stops being the one on screen. The simulated camera
  /// and microphone keep streaming: they are local files the user picked, so
  /// nothing is being observed, and ending them would drop a half-finished
  /// scan or stop playback the user comes back to.
  ///
  /// Two properties this must keep, both easy to lose:
  ///   * it runs BEFORE [pauseWebView] at every call site — the iOS
  ///     per-instance pause blocks the page's JS thread, so JS posted after it
  ///     would not run until the site is resumed;
  ///   * it is NOT folded into [pauseWebView], which early-returns for
  ///     notification and background-audio sites. Those sites may keep running
  ///     JS and audio in the background. The camera is not covered by either.
  Future<void> stopRealCapture() async {
    await ScreenShare.instance.endSite(siteId);
    await controller?.evaluateJavascript(
      "if (typeof globalThis.__wsStopRealCapture === 'function') "
      'globalThis.__wsStopRealCapture();',
    );
  }

  /// Tell a background-audio site's page whether the app is backgrounded
  /// (BGAUDIO-012), so its media-session shim can mask the page-visibility
  /// APIs and re-issue `play()` if the page stopped itself anyway.
  ///
  /// A no-op for every other site: masking visibility for a page the user did
  /// not opt in for would keep timers and players running that should stop.
  /// Main frame only — the shim relays the state to its own subframes.
  Future<void> setBackgroundPlayback({required bool active}) async {
    if (!effectiveBackgroundAudioEnabled) return;
    await controller?.evaluateJavascript(
      'if(window.__wsMediaBackground)window.__wsMediaBackground($active);',
    );
  }

  /// Pause every playing media element in the page's main frame (BGAUDIO-009).
  ///
  /// A no-op for sites with [effectiveBackgroundAudioEnabled] — that toggle
  /// exists precisely to keep them sounding. For every other site this is what
  /// makes "Background audio: off" mean anything: neither [pauseWebView] nor
  /// [pauseForAppLifecycle] stops the media pipeline (they freeze JS timers,
  /// see the pause spec), so without it a site the user never opted in for
  /// keeps playing after it loses the screen and holds the OS transport
  /// controls up with it.
  ///
  /// Same ordering constraint as [stopRealCapture]: it must be
  /// dispatched BEFORE the pause, since the iOS per-instance pause blocks the
  /// page's JS thread and this would sit queued behind it. Main frame only
  /// (`evaluateJavascript` targets it) — a player inside a cross-origin
  /// subframe is accepted degradation, as in BGAUDIO-008.
  Future<void> pauseMediaPlayback() async {
    if (effectiveBackgroundAudioEnabled) return;
    await controller?.evaluateJavascript(PageJs.mediaPause.script);
  }

  Future<void> resumeWebView() async {
    if (controller == null) return;
    await controller!.resume();
    LogTag.webView.debug(
        'Resumed webview for "$name" (siteId: $siteId)', sensitive: true);
  }

  /// App-lifecycle pause: per-instance pause + process-global JS timer pause.
  ///
  /// The global timer pause is intentional here: when the whole app goes to
  /// background we want every loaded webview's JS frozen, not just the active
  /// one. Pair with [resumeFromAppLifecycle] on resume.
  Future<void> pauseForAppLifecycle() async {
    // Bind both calls to one local controller: disposeWebView() only nulls
    // the `controller` field (the native webview stays alive until the next
    // widget rebuild), so a concurrent dispose landing between these awaits
    // would, if we re-read `controller!`, throw and skip the process-global
    // pauseAllJsTimers — stranding every webview's JS timers. The local keeps
    // both calls on the same still-live controller.
    final c = controller;
    if (c == null) return;
    await c.pause();
    await c.pauseAllJsTimers();
    LogTag.webView.debug(
        'App-lifecycle paused webview for "$name" (siteId: $siteId)',
        sensitive: true);
  }

  /// Inverse of [pauseForAppLifecycle].
  Future<void> resumeFromAppLifecycle() async {
    // See [pauseForAppLifecycle]: bind both calls to one local controller so a
    // concurrent dispose can't strand the process-global resumeAllJsTimers.
    final c = controller;
    if (c == null) return;
    await c.resume();
    await c.resumeAllJsTimers();
    LogTag.webView.debug(
        'App-lifecycle resumed webview for "$name" (siteId: $siteId)',
        sensitive: true);
  }
}
