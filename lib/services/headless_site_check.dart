import 'dart:async';
import 'dart:collection';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/http_auth_challenge.dart';
import 'package:webspace/services/webview_tls.dart';
import 'package:webspace/services/page_scripts.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/page_phase.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_controller.dart' show markNetworkBlocked;
import 'package:webspace/services/log_service.dart';

/// The headless webview a background wake opens for a site that has no live
/// one (NOTIF-016).
abstract final class HeadlessSiteChecks {
  /// Opens [config]'s site in a headless webview for a background wake
  /// (NOTIF-016) and starts loading [WebViewConfig.initialUrl]. Returns the
  /// check, or why there is none; a check is the caller's to dispose.
  ///
  /// It is the site in every way that reaches the network or the page:
  /// container, proxy, user agent, shims, user scripts, blockers, and the
  /// notification polyfill's handler. It has no user, so it is stricter than
  /// the site's tab: the top document stays on the site, no window opens,
  /// every permission and JS dialog is declined, downloads are dropped, an
  /// untrusted certificate is refused unless already pinned, and an HTTP
  /// auth challenge is answered only from saved sign-ins.
  static Future<(HeadlessSiteCheck?, WakeSkip?)> openHeadlessCheck(
      WebViewConfig config) async {
    final binding = WebViewFactory.bindingFor(config);
    // SEC-009: a proxy the site expects but the platform cannot bind must
    // not become a direct connection.
    if (binding.proxyUnavailable) return (null, WakeSkip.proxyUnavailable);
    // LEAK-016: nor an onion service a direct one.
    if (WebViewFactory.refusesLoad(binding, url: config.initialUrl) !=
        null) {
      return (null, WakeSkip.onionNeedsProxy);
    }
    ProxyManager.noteStoreProxy(binding.containerId, proxy: binding.proxy);
    final posture = config.posture;
    BlockStatsService.instance.setSiteContributes(posture.siteId,
        contributes: posture.blocking.contributesStats);
    final page = PageScripts.buildPageScripts(config);
    final httpAuth = httpAuthSessionFor(config);
    final check = HeadlessSiteCheck._();
    final created = Completer<inapp.InAppWebViewController>();
    String? loadStartUrl;
    // The check's documents, which a script its handlers evaluate lands in.
    final phases = PagePhases(
      blocking: posture.blocking,
      dnsLevel: () => config.effectiveDnsLevel,
    );
    final settings = WebViewFactory.siteSettings(
      binding,
      posture: posture,
      textZoom: page.textZoom,
      desktopMode: page.desktopMode,
    )
      ..useShouldInterceptRequest = false
      ..useOnLoadResource = false
      ..supportMultipleWindows = false
      ..javaScriptCanOpenWindowsAutomatically = false
      // Nothing plays in a check: no one is there to hear it, and on iOS
      // audio would ride the background audio session (NOTIF-015).
      ..mediaPlaybackRequiresUserGesture = true;
    check._settings = settings;
    final headless = inapp.HeadlessInAppWebView(
      initialSettings: settings,
      initialUserScripts: UnmodifiableListView(page.userScripts),
      onWebViewCreated: (controller) {
        phases.on(PageEvent.viewCreated, view: controller.platform);
        PageHandlers.registerPageHandlers(
          controller,
          config: config,
          userScriptService: page.userScriptService,
          page: (
            sourceUrl: () => loadStartUrl,
            document: () => phases.page(controller),
          ),
        );
        if (!created.isCompleted) created.complete(controller);
      },
      // HTTPS-001 with no fallback: a check that cannot reach the site over
      // https fails rather than going out in plaintext.
      shouldOverrideUrlLoading: (_, navigationAction) async =>
          WebViewFactory.onSiteNavigationPolicy(config, navigationAction: navigationAction,
              popup: null,
              refusePlainHttp: posture.blocking.httpsUpgrade),
      onLoadStart: (controller, url) {
        phases.on(PageEvent.loadStarted, view: controller.platform);
        loadStartUrl = url?.toString();
        check._loading = true;
      },
      onLoadStop: (_, _) => check._loading = false,
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame ?? true) check._loading = false;
      },
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => inapp.PermissionResponse(
        resources: request.resources,
        action: inapp.PermissionResponseAction.DENY,
      ),
      onGeolocationPermissionsShowPrompt: (_, origin) async =>
          inapp.GeolocationPermissionShowPromptResponse(
              origin: origin, allow: false, retain: false),
      onJsAlert: (_, _) async => inapp.JsAlertResponse(
          handledByClient: true, action: inapp.JsAlertResponseAction.CONFIRM),
      onJsConfirm: (_, _) async => inapp.JsConfirmResponse(
          handledByClient: true, action: inapp.JsConfirmResponseAction.CANCEL),
      onJsPrompt: (_, _) async => inapp.JsPromptResponse(
          handledByClient: true, action: inapp.JsPromptResponseAction.CANCEL),
      onDownloadStarting: (_, _) async => inapp.DownloadStartResponse(
          handled: true, action: inapp.DownloadStartResponseAction.CANCEL),
      // No view: an https upgrade the certificate refuses has no plaintext
      // fallback to load in a check.
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewTls.handleServerTrust(null, challenge: challenge, prompt: null),
      onReceivedHttpAuthRequest: (controller, challenge) =>
          answerHttpAuthChallenge(
            routerIdentity: routerIdentityForConfig(config),
            session: httpAuth,
            challenge: challenge,
          ),
      onRenderProcessGone: (controller, _) {
        phases.on(PageEvent.rendererGone, view: controller.platform);
        check._gone = true;
      },
      onWebContentProcessDidTerminate: (controller) {
        phases.on(PageEvent.rendererGone, view: controller.platform);
        check._gone = true;
      },
    );
    check._webview = headless;
    final inapp.InAppWebViewController controller;
    try {
      await headless.run();
      controller = await created.future.timeout(_headlessCreateTimeout);
    } on TimeoutException {
      await check.dispose();
      return (null, WakeSkip.headlessFailed);
    } on PlatformException {
      await check.dispose();
      return (null, WakeSkip.headlessFailed);
    }
    check._controller = controller;
    // Android blocks sub-resources in a native interceptor, attached here by
    // the webview's id so it carries this site's id and level, not those of
    // whichever site next asks to attach. Without one a site that blocks
    // would load the page's trackers unfiltered, so its load never starts.
    if (hostIsAndroid) {
      final attached = await WebInterceptNative.attachToHeadless(
        headlessId: headless.id,
        siteId: posture.siteId,
        dnsLevel: config.effectiveDnsLevel,
        localCdn: posture.blocking.localCdn,
        contentBlock: posture.blocking.contentBlock,
      );
      if (!attached &&
          (posture.blocking.dns ||
              posture.blocking.contentBlock ||
              posture.blocking.localCdn)) {
        await check.dispose();
        return (null, WakeSkip.blockersNotAttached);
      }
    }
    final home = Uri.tryParse(config.initialUrl);
    final url = posture.blocking.httpsUpgrade &&
            home != null &&
            home.scheme == 'http' &&
            (!home.hasPort || home.port == 80)
        ? home.replace(scheme: 'https', port: null).toString()
        : config.initialUrl;
    check._loading = true;
    try {
      await controller.loadUrl(
        urlRequest: inapp.URLRequest(
          url: inapp.WebUri(url),
          headers: WebViewFactory.navigationHeaders(config),
        ),
      );
    } on PlatformException {
      await check.dispose();
      return (null, WakeSkip.headlessFailed);
    }
    return (check, null);
  }

  static const Duration _headlessCreateTimeout = Duration(seconds: 10);
}

/// A site's page loaded with no view, for one background wake (NOTIF-016).
/// Built by [HeadlessSiteChecks.openHeadlessCheck].
class HeadlessSiteCheck {
  HeadlessSiteCheck._();

  /// A check over [webview] and its [controller], running with [settings],
  /// for a test of how it ends.
  @visibleForTesting
  HeadlessSiteCheck.over(
    inapp.HeadlessInAppWebView webview, {
    required inapp.InAppWebViewController controller,
    required inapp.InAppWebViewSettings settings,
  }) : _controller = controller {
    _webview = webview;
    _settings = settings;
  }

  late final inapp.HeadlessInAppWebView _webview;
  late final inapp.InAppWebViewSettings _settings;
  inapp.InAppWebViewController? _controller;
  bool _loading = false;
  bool _gone = false;
  bool _disposed = false;

  /// Null once the page is gone: disposed, or its renderer died.
  bool? get isLoading => _gone || _disposed ? null : _loading;

  Future<String?> title() async {
    final c = _controller;
    if (c == null || _gone || _disposed) return null;
    return c.getTitle();
  }

  /// Ends the check. Its webview loads nothing more before it goes, since
  /// the process-wide proxy rule may move as soon as this returns
  /// (PROXY-008).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_controller case final controller? when markNetworkBlocked(_settings)) {
      try {
        await controller.setSettings(settings: _settings);
      } on PlatformException catch (e) {
        LogTag.backgroundTask
            .warning('could not stop a check loading: $e', sensitive: true);
      } on MissingPluginException catch (e) {
        LogTag.backgroundTask
            .warning('could not stop a check loading: $e', sensitive: true);
      }
    }
    await _webview.dispose();
  }
}
