import 'package:webspace/platform/host_platform.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/anti_fingerprinting_shim.dart';
import 'package:webspace/services/language_shim.dart';
import 'package:webspace/services/launch_nonce.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/content_blocker_shim.dart';
import 'package:webspace/services/procedural_cosmetic_shim.dart';
import 'package:webspace/services/capture_shim.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity_shim.dart';
import 'package:webspace/services/worker_shim.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/notification_polyfill_shim.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/page_js.dart';

/// The user scripts a site webview starts with: every shim its posture asks
/// for, in the order they must run.
abstract final class PageScripts {
  /// Everything the page-facing JS surface of a site needs, derived from
  /// [config] alone. Shared with [WebViewFactory.createPopupWebView] so a popup opened by a
  /// site carries the same shims as the webview that spawned it. The list is
  /// in injection order.
  static ({
    int textZoom,
    List<inapp.UserScript> userScripts,
    PageZoomPlan zoomPlan,
    bool desktopMode,
    UserScriptService userScriptService,
  }) buildPageScripts(WebViewConfig config) {
    final posture = config.posture;
    final textZoom = WebViewFactory.systemTextZoomPercent();
    final desktopMode = isDesktopUserAgent(posture.page.userAgent);
    final zoomPlan = planPageZoom(
      zoomPercent: posture.page.zoomPercent,
      isAndroid: hostIsAndroid,
      isIOS: hostIsIOS,
      desktopMode: desktopMode,
    );
    final scoped = _scopedShims(posture);
    final userScriptService = UserScriptService(
      scripts: posture.page.userScripts,
      onConfirmScriptFetch: config.hooks.confirmScriptFetch,
      proxy: posture.container.proxy,
    );

    final userScripts = <inapp.UserScript>[
      if (scoped.webGl case final js?)
        pageShim('webgl_kill_switch', js: js, frames: ShimFrames.all),
      pageShim('do_not_track',
          js: PageJs.doNotTrack.script, frames: ShimFrames.all),
    ];
    // Capture shims. Each asks Dart for the site's decision through its
    // kind's request handler, so the popup, the remembered choice and the
    // archive-tier override are enforced in one place. A combined audio+video
    // getUserMedia is split by the microphone shim and its video half
    // re-issued through the live entry point, so the shims compose whichever
    // order they were injected in.
    //
    // The camera and microphone reach every frame, so a QR scanner in a
    // cross-origin iframe is covered. Screen sharing does not (SHARE-005), and
    // nothing under it can back-door one: no platform this app ships offers
    // display capture to a WKWebView / Android WebView, and the Linux WPE
    // plugin denies a display-device user-media request natively before Dart
    // is consulted. Its shim re-reads `window === window.top` itself, so the
    // guard survives a platform that stops honouring the flag.
    if (config.grants != null) {
      for (final kind in CaptureKind.values) {
        userScripts.add(pageShim(
          kind.shimGroup,
          js: buildCaptureShim(kind),
          frames: kind.frames,
        ));
      }
    }

    userScripts.addAll([
      ..._passkeyShims(config.passkeys),
      // Cross-domain taps then reach shouldOverrideUrlLoading, which has a
      // reliable gesture, instead of onCreateWindow (issue #405).
      pageShim('target_blank_rewrite', js: PageJs.targetBlankRewrite.script,
          frames: ShimFrames.all),
      if (scoped.antiFingerprinting case final js?)
        pageShim('anti_fingerprinting', js: js, frames: ShimFrames.all),
      ..._downloadShims(),
      ..._identityShims(posture, scoped: scoped, desktopMode: desktopMode),
      ..._zoomShims(posture, plan: zoomPlan,
          textZoom: textZoom, desktopMode: desktopMode),
      pageShim(
          'notification_polyfill',
          js: buildNotificationPolyfillShim(
            siteId: posture.siteId,
            notificationsEnabled: posture.page.notifications,
          ),
          frames: ShimFrames.all),
      ..._mediaSessionShims(config),
      pageShim('location_spoof', js: scoped.location, frames: ShimFrames.all),
      ..._contentBlockerShims(config),
      if (posture.blocking.clearUrls)
        pageShim('clearurl_share', js: PageJs.clearUrlShare.script,
            frames: ShimFrames.all),
      if (scoped.language case final js?)
        pageShim('language_override', js: js, frames: ShimFrames.all),
      // An iframe can create its own workers.
      if (buildWorkerShimScript(workerScopeBodies(scoped)) case final js?)
        pageShim('worker_shim', js: js, frames: ShimFrames.all),
      ..._blockInterceptorShims(config),
      ...userScriptService.buildInitialUserScripts(),
    ]);
    return (
      textZoom: textZoom,
      userScripts: userScripts,
      zoomPlan: zoomPlan,
      desktopMode: desktopMode,
      userScriptService: userScriptService,
    );
  }

  /// The shims whose values a worker can read too, built once for the page
  /// and its workers.
  ///
  /// Tracking Protection strips WebGL outright: the strongest answer to its
  /// fingerprint, and on Android a crash workaround, since a
  /// fingerprinter's `getContext('webgl')` walks a Chromium blocklist path
  /// that SIGTRAPs the renderer (`partition_alloc_support.cc:770`) and no
  /// setting turns WebGL off. Turning Tracking Protection off for a site
  /// brings it back for maps and 3D viewers (issue #391). The incognito
  /// fingerprint rerolls per launch (ETP-028). The location zone was resolved
  /// when the site was saved, so the polygon dataset never loads here.
  static ScopedShims _scopedShims(SitePosture p) {
    final tp = p.fingerprint.trackingProtection;
    final ua = p.page.userAgent;
    final language = p.page.language;
    final location = p.location;
    return (
      webGl: tp ? PageJs.webGlKillSwitch.script : null,
      antiFingerprinting: buildAntiFingerprintingScriptSource(
        siteId: p.siteId,
        trackingProtectionEnabled: tp,
        incognito: p.container.incognito,
        launchNonce: LaunchNonce.value,
        resetNonce: p.fingerprint.resetNonce,
        letterbox: p.fingerprint.letterbox,
      ),
      identity:
          ua == null || ua.isEmpty ? null : buildUserAgentIdentityShim(ua),
      location: LocationSpoofService.buildScript(location),
      timezone: location.timezone,
      language: language == null ? null : buildLanguageShim(language),
    );
  }

  /// Passkeys through the Credential Manager bridge (PASSKEY-003), in every
  /// frame, so a cross-origin frame is refused by the handler the way
  /// Chromium refuses an undelegated one rather than by a missing API. The
  /// WebView backend needs nothing: the engine exposes WebAuthn itself.
  /// WebKit answers WebAuthn on its own with no switch to stop it, so on iOS
  /// and macOS "no passkeys" is the block shim, in every frame (PASSKEY-013).
  static List<inapp.UserScript> _passkeyShims(PasskeyAccess? passkeys) => [
        if (passkeys?.backend == PasskeyBackend.credentialManager)
          pageShim('passkey', js: PageJs.passkey.script, frames: ShimFrames.all),
        if (passkeys == null && PasskeyAccess.hostIsApple)
          pageShim('passkey_block', js: PageJs.passkeyBlock.script,
              frames: ShimFrames.all),
      ];

  /// Blob downloads. The capture serves a site whose CSP `connect-src`
  /// refuses `fetch(blob:)`: [WebViewDownloads.handleBlobDownload] reads the Blob itself.
  /// Android's DownloadListener never fires for a `blob:` link, so the click
  /// is bridged too; WebKit raises onDownloadStartRequest for it natively.
  static List<inapp.UserScript> _downloadShims() => [
        pageShim('blob_url_capture',
            js: PageJs.blobUrlCapture.script, frames: ShimFrames.top),
        if (hostIsAndroid)
          pageShim('blob_download_click_intercept',
              js: PageJs.blobDownloadClickIntercept.script, frames: ShimFrames.top),
      ];

  /// The per-site UA's identity. A desktop UA also gets userAgentData,
  /// maxTouchPoints, matchMedia and the viewport of a desktop; any UA gets
  /// the navigator fields the host engine would otherwise fill in its own
  /// name (vendor, productSub, oscpu, buildID, platform).
  static List<inapp.UserScript> _identityShims(
    SitePosture p, {
    required ScopedShims scoped,
    required bool desktopMode,
  }) =>
      [
        if (desktopMode)
          pageShim('desktop_mode_shim',
              js: buildDesktopModeShim(p.page.userAgent ?? ''),
              frames: ShimFrames.all),
        if (scoped.identity case final js?)
          pageShim('ua_identity_shim', js: js, frames: ShimFrames.all),
      ];

  /// The page's scale: WebKit's default viewport fix (desktop mode owns the
  /// viewport itself), the OS text size where there is no `textZoom`
  /// setting, and the per-site zoom on the channel [planPageZoom] picked.
  static List<inapp.UserScript> _zoomShims(
    SitePosture p, {
    required PageZoomPlan plan,
    required int textZoom,
    required bool desktopMode,
  }) {
    final zoom = p.page.zoomPercent;
    final pageZoom = switch (plan.channel) {
      PageZoomChannel.none => null,
      PageZoomChannel.cssZoom => buildPageZoomCssShim(zoom),
      PageZoomChannel.viewportMeta => () {
          final (portrait, landscape) = WebViewFactory.viewExtents();
          return buildPageZoomViewportShim(
            zoomPercent: zoom,
            pinLayoutWidth: plan.pinLayoutWidth,
            portraitWidth: portrait,
            landscapeWidth: landscape,
          );
        }(),
    };
    return [
      if ((hostIsIOS || hostIsMacOS) && !desktopMode)
        pageShim('default_viewport', js: PageJs.defaultViewport.script,
            frames: ShimFrames.top),
      if (!hostIsAndroid)
        pageShim('system_text_zoom', js: buildTextZoomShim(textZoom),
            frames: ShimFrames.all),
      if (pageZoom != null)
        pageShim('page_zoom', js: pageZoom, frames: ShimFrames.all),
    ];
  }

  /// BGAUDIO-006, on background-audio sites only. The log line is the first
  /// link of BGAUDIO-007's chain: its absence from an App Logs export says
  /// the toggle is off, which nothing downstream can tell from a broken
  /// bridge.
  static List<inapp.UserScript> _mediaSessionShims(WebViewConfig config) {
    if (!config.backgroundAudioEnabled ||
        !MediaSessionService.instance.isSupported) {
      return const [];
    }
    LogTag.mediaSession.debug('Bridge armed for this site');
    return [
      pageShim('media_session_shim', js: PageJs.mediaSession.script,
          frames: ShimFrames.all),
    ];
  }

  /// Cosmetic filtering and `$csp=`. The early CSS hides before first paint;
  /// the generic class/id scan and the procedural actions (`:has-text()`,
  /// `:upward()`, `:remove()`) need a parsed body and the engine.
  static List<inapp.UserScript> _contentBlockerShims(WebViewConfig config) {
    if (!config.posture.blocking.contentBlock) return const [];
    final blocker = ContentBlockerService.instance;
    final url = config.initialUrl;
    final csp = blocker.cspFor(url);
    final engine = blocker.usingRustEngine;
    final procedural = engine
        ? buildProceduralCosmeticShim(blocker.proceduralActionsFor(url))
        : null;
    return [
      if (blocker.getEarlyCssScript(url) case final js?)
        pageShim('content_blocker_early_css', js: js, frames: ShimFrames.top),
      if (csp != null && csp.isNotEmpty)
        pageShim('content_blocker_csp', js: buildContentBlockerCspShim(csp),
            frames: ShimFrames.top),
      if (engine)
        pageShim('generic_cosmetic', js: PageJs.genericCosmetic.script,
            frames: ShimFrames.top, at: ShimTime.end),
      if (procedural != null)
        pageShim('procedural_cosmetic', js: procedural,
            frames: ShimFrames.top, at: ShimTime.end),
    ];
  }

  /// WebKit's sub-resource accounting and blocking, which Android does
  /// natively. The observer runs whether or not a list is loaded, since the
  /// per-site log reflects the visit rather than the blockers.
  static List<inapp.UserScript> _blockInterceptorShims(WebViewConfig config) {
    if (hostIsAndroid) return const [];
    final blocks = (config.effectiveDnsLevel > kDnsLevelOff &&
            DnsBlockService.instance.hasBlocklist) ||
        (config.posture.blocking.contentBlock &&
            ContentBlockerService.instance.hasRules);
    return [
      pageShim('block_resource_observer', js: PageJs.blockResourceObserver.script,
          frames: ShimFrames.all),
      if (blocks)
        pageShim('block_js_interceptor', js: PageJs.blockJsInterceptor.script,
            frames: ShimFrames.all),
    ];
  }
}
