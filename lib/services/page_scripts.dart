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
import 'package:webspace/services/theme_color_scheme_shim.dart';
import 'package:webspace/services/capture_shim.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity_shim.dart';
import 'package:webspace/services/worker_shim.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/notification_polyfill_shim.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/icon_link_watcher_shim.dart';
import 'package:webspace/services/search_link_watcher_shim.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/webkit_block_reports.dart';

/// What a site's own webview installs beyond the scripts its posture asks
/// for, which a popup and a headless check share: the watchers that report
/// into the site's icon and its search, and how a remote hands focus back
/// from its page ([keys]).
typedef OwnView = ({PageKeys? keys});

/// The user scripts a site webview starts with: every shim its posture asks
/// for, in [ShimGroup]'s order.
abstract final class PageScripts {
  /// Everything the page-facing JS surface of a site needs, derived from
  /// [config], and from [own] for the site's own webview (null for a popup,
  /// which shares the shims of the site that spawned it, and for a headless
  /// check).
  static ({
    int textZoom,
    List<inapp.UserScript> userScripts,
    PageZoomPlan zoomPlan,
    bool desktopMode,
    UserScriptService userScriptService,
  }) buildPageScripts(WebViewConfig config, {required OwnView? own}) {
    final posture = config.posture;
    final desktopMode = isDesktopUserAgent(posture.page.userAgent);
    final shims = _PageShims(
      config: config,
      own: own,
      textZoom: WebViewFactory.systemTextZoomPercent(),
      desktopMode: desktopMode,
      zoomPlan: planPageZoom(
        zoomPercent: posture.page.zoomPercent,
        isAndroid: hostIsAndroid,
        isIOS: hostIsIOS,
        desktopMode: desktopMode,
      ),
      userScripts: UserScriptService(
        scripts: posture.page.userScripts,
        onConfirmScriptFetch: config.hooks.confirmScriptFetch,
        proxy: posture.container.proxy,
      ),
    );
    return (
      textZoom: shims.textZoom,
      userScripts: [
        for (final group in ShimGroup.values)
          for (final js in shims.of(group)) pageShim(group, js: js),
      ],
      zoomPlan: shims.zoomPlan,
      desktopMode: desktopMode,
      userScriptService: shims.userScripts,
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

}

/// The scripts of each [ShimGroup] one webview build installs.
final class _PageShims {
  _PageShims({
    required this.config,
    required this.own,
    required this.textZoom,
    required this.desktopMode,
    required this.zoomPlan,
    required this.userScripts,
  }) : scoped = PageScripts._scopedShims(config.posture);

  final WebViewConfig config;
  final OwnView? own;
  final int textZoom;
  final bool desktopMode;
  final PageZoomPlan zoomPlan;
  final UserScriptService userScripts;
  final ScopedShims scoped;

  SitePosture get posture => config.posture;

  /// The scripts [group] installs here, none where the posture or the host
  /// asks for none.
  List<String> of(ShimGroup group) => switch (group) {
        ShimGroup.webglKillSwitch => [?scoped.webGl],
        ShimGroup.doNotTrack => [PageJs.doNotTrack.script],
        // Each asks Dart for the site's decision through its kind's request
        // handler, so the popup, the remembered choice and the archive-tier
        // override are enforced in one place. A combined audio+video
        // getUserMedia is split by the microphone shim and its video half
        // re-issued through the live entry point, so the shims compose in
        // either order. Screen sharing reaches the top frame only (SHARE-005),
        // and nothing under it can back-door one: no platform this app ships
        // offers display capture to a WKWebView / Android WebView, and the
        // Linux WPE plugin denies a display-device user-media request
        // natively before Dart is consulted.
        ShimGroup.cameraStream ||
        ShimGroup.microphoneStream ||
        ShimGroup.screenShare =>
          [
            if (config.grants != null)
              for (final kind in CaptureKind.values)
                if (kind.shimGroup == group) buildCaptureShim(kind),
          ],
        // Passkeys through the Credential Manager bridge (PASSKEY-003), so a
        // cross-origin frame is refused by the handler the way Chromium
        // refuses an undelegated one rather than by a missing API. The
        // WebView backend needs nothing: the engine exposes WebAuthn itself.
        ShimGroup.passkey => [
            if (config.passkeys?.backend == PasskeyBackend.credentialManager)
              PageJs.passkey.script,
          ],
        // WebKit answers WebAuthn on its own with no switch to stop it, so on
        // iOS and macOS "no passkeys" is the block shim (PASSKEY-013).
        ShimGroup.passkeyBlock => [
            if (config.passkeys == null && PasskeyAccess.hostIsApple)
              PageJs.passkeyBlock.script,
          ],
        // Cross-domain taps then reach shouldOverrideUrlLoading, which has a
        // reliable gesture, instead of onCreateWindow (issue #405).
        ShimGroup.targetBlankRewrite => [PageJs.targetBlankRewrite.script],
        ShimGroup.antiFingerprinting => [?scoped.antiFingerprinting],
        // The capture serves a site whose CSP `connect-src` refuses
        // `fetch(blob:)`: [WebViewDownloads.handleBlobDownload] reads the
        // Blob itself. Android's DownloadListener never fires for a `blob:`
        // link, so the click is bridged too; WebKit raises
        // onDownloadStartRequest for it natively.
        ShimGroup.blobUrlCapture => [PageJs.blobUrlCapture.script],
        ShimGroup.blobDownloadClickIntercept => [
            if (hostIsAndroid) PageJs.blobDownloadClickIntercept.script,
          ],
        // A desktop UA also gets userAgentData, maxTouchPoints, matchMedia and
        // the viewport of a desktop; any UA gets the navigator fields the host
        // engine would otherwise fill in its own name.
        ShimGroup.desktopMode => [
            if (desktopMode) buildDesktopModeShim(posture.page.userAgent ?? ''),
          ],
        ShimGroup.uaIdentity => [?scoped.identity],
        // WebKit's default viewport fix; desktop mode owns the viewport.
        ShimGroup.defaultViewport => [
            if ((hostIsIOS || hostIsMacOS) && !desktopMode)
              PageJs.defaultViewport.script,
          ],
        // The OS text size where there is no `textZoom` setting.
        ShimGroup.systemTextZoom => [
            if (!hostIsAndroid) buildTextZoomShim(textZoom),
          ],
        ShimGroup.pageZoom => [?_pageZoom()],
        ShimGroup.notificationPolyfill => [
            buildNotificationPolyfillShim(
              siteId: posture.siteId,
              notificationsEnabled: posture.page.notifications,
            ),
          ],
        ShimGroup.mediaSession => _mediaSession(),
        ShimGroup.locationSpoof => [scoped.location],
        // The early CSS hides before first paint; the generic class/id scan
        // and the procedural actions (`:has-text()`, `:upward()`,
        // `:remove()`) need a parsed body and the engine.
        ShimGroup.contentBlockerEarlyCss => [
            if (_blocker case final b?) ?b.getEarlyCssScript(config.initialUrl),
          ],
        ShimGroup.contentBlockerCsp => [
            if (_blocker?.cspFor(config.initialUrl) case final csp?
                when csp.isNotEmpty)
              buildContentBlockerCspShim(csp),
          ],
        ShimGroup.genericCosmetic => [
            if (_blocker?.usingRustEngine ?? false) PageJs.genericCosmetic.script,
          ],
        ShimGroup.proceduralCosmetic => [
            if (_blocker case final b? when b.usingRustEngine)
              ?buildProceduralCosmeticShim(
                  b.proceduralActionsFor(config.initialUrl)),
          ],
        ShimGroup.clearUrlShare => [
            if (posture.blocking.clearUrls) PageJs.clearUrlShare.script,
          ],
        ShimGroup.languageOverride => [?scoped.language],
        // The first document gets it too; the controller replaces it when the
        // theme changes ([LiveShim.themeColorScheme]).
        ShimGroup.themeColorScheme => [
            buildThemeColorSchemeShim(posture.page.theme),
          ],
        ShimGroup.worker => [
            ?buildWorkerShimScript(workerScopeBodies(scoped)),
          ],
        // WebKit's sub-resource accounting and blocking, which Android does
        // natively. The observer runs whether or not a list is loaded, since
        // the per-site log reflects the visit rather than the blockers. The
        // interceptor goes in whenever the site asks for a blocker, data or
        // not: a list that lands later reaches it through its bloom, where one
        // left out at build would leave the view unblocked for its life.
        ShimGroup.blockResourceObserver => [
            if (!hostIsAndroid) PageJs.blockResourceObserver.script,
          ],
        ShimGroup.blockJsInterceptor => [
            if (!hostIsAndroid &&
                (posture.blocking.dns || posture.blocking.contentBlock))
              PageJs.blockJsInterceptor
                  .withConfig({'webKitReports': WebKitBlockReports.active}),
          ],
        ShimGroup.scriptFetch => [?userScripts.shimScript],
        ShimGroup.userScriptsAtStart =>
          userScripts.sourcesAt(UserScriptInjectionTime.atDocumentStart),
        ShimGroup.userScriptsAtEnd =>
          userScripts.sourcesAt(UserScriptInjectionTime.atDocumentEnd),
        ShimGroup.remoteEdge => [
            if (own?.keys == PageKeys.remote) PageFocus.edgeScript,
          ],
        // A popup, which shares the site's config, never reports into the
        // site's icon or search.
        ShimGroup.iconLinkWatcher => [
            if (own != null && config.siteIcon != null)
              buildIconLinkWatcherShim(),
          ],
        ShimGroup.searchLinkWatcher => [
            if (own != null && config.siteSearch != null)
              buildSearchLinkWatcherShim(),
          ],
      };

  /// The content blocker, where the site asks for cosmetic filtering.
  ContentBlockerService? get _blocker =>
      posture.blocking.contentBlock ? ContentBlockerService.instance : null;

  /// The per-site zoom on the channel [planPageZoom] picked.
  String? _pageZoom() {
    final zoom = posture.page.zoomPercent;
    return switch (zoomPlan.channel) {
      PageZoomChannel.none => null,
      PageZoomChannel.cssZoom => buildPageZoomCssShim(zoom),
      PageZoomChannel.viewportMeta => () {
          final (portrait, landscape) = WebViewFactory.viewExtents();
          return buildPageZoomViewportShim(
            zoomPercent: zoom,
            pinLayoutWidth: zoomPlan.pinLayoutWidth,
            portraitWidth: portrait,
            landscapeWidth: landscape,
          );
        }(),
    };
  }

  /// BGAUDIO-006, on background-audio sites only. The log line is the first
  /// link of BGAUDIO-007's chain: its absence from an App Logs export says
  /// the toggle is off, which nothing downstream can tell from a broken
  /// bridge.
  List<String> _mediaSession() {
    if (!config.backgroundAudioEnabled ||
        !MediaSessionService.instance.isSupported) {
      return const [];
    }
    LogTag.mediaSession.debug('Bridge armed for this site');
    return [PageJs.mediaSession.script];
  }
}
