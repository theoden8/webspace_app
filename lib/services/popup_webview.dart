import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/http_auth_challenge.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/webview_tls.dart';
import 'package:webspace/services/page_scripts.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/webview.dart';

/// The webview a site's `window.open` gets, built from its parent's posture.
abstract final class PopupWebView {
  /// [WebViewConfig] of the webview that asked for a popup window, keyed by
  /// the `windowId` the host UI is handed. The host builds the popup widget
  /// from a `BuildContext` that knows nothing about the site, so the parent's
  /// posture would otherwise be lost between `onCreateWindow` and
  /// [createPopupWebView] — and a popup with no shims, no container and no
  /// proxy is a hole straight through every per-site setting.
  static final Map<int, WebViewConfig> popupParentConfigs = {};

  /// Create a popup webview for handling window.open() calls.
  /// Used for Cloudflare challenges and other popups that require a real window.
  ///
  /// [config] defaults to the parent webview's, recorded when the popup was
  /// requested. The popup inherits its identity (UA, shims, user scripts),
  /// its store binding and its proxy: it is the same site, in a dialog.
  static Widget createPopupWebView({
    required int windowId,
    WebViewConfig? config,
    VoidCallback? onCloseWindow,
  }) {
    final parent = config ?? popupParentConfigs[windowId];
    if (parent == null) {
      // No parent posture to inherit means we cannot tell what the popup is
      // allowed to be. Render nothing rather than a fully-privileged webview.
      return const SizedBox.shrink();
    }
    final binding = WebViewFactory.bindingFor(parent);
    // Same fail-closed rule as the site webview: a proxy the site expects but
    // the platform cannot honor must not become a direct connection.
    if (binding.proxyUnavailable) return const SizedBox.shrink();
    ProxyManager.noteStoreProxy(binding.containerId, proxy: binding.proxy);
    final page = PageScripts.buildPageScripts(parent);
    final httpAuth = httpAuthSessionFor(parent);
    final settings = WebViewFactory.siteSettings(
      binding,
      posture: parent.posture,
      textZoom: page.textZoom,
      desktopMode: page.desktopMode,
    );
    PlatformWebViewController? view;
    final popup = inapp.InAppWebView(
      windowId: windowId,
      initialSettings: settings,
      initialUserScripts: UnmodifiableListView(page.userScripts),
      onWebViewCreated: (controller) {
        view = PlatformWebViewController(controller,
            pauseHack: PauseTimersHackState(), settings: settings);
        PageHandlers.registerPageHandlers(
          controller,
          config: parent,
          userScriptService: page.userScriptService,
          sourceUrl: () => parent.initialUrl,
        );
      },
      // The popup exists for one challenge: its documents pass the site's
      // DNS and content-blocker checks, and its top document stays on a
      // captcha host or the site's own domain (CAPTCHA-010).
      shouldOverrideUrlLoading: (_, navigationAction) async =>
          WebViewFactory.onSiteNavigationPolicy(parent, navigationAction: navigationAction,
              allowCaptcha: true),
      onCloseWindow: (controller) {
        onCloseWindow?.call();
      },
      // Honor the same trust list as the parent webview, but never
      // prompt — a popup is a child of a flow the user already
      // approved, and surfacing a second dialog inside a Cloudflare
      // verification iframe would be more confusing than the cancel
      // it falls back to.
      onReceivedServerTrustAuthRequest: (controller, challenge) =>
          WebViewTls.handleServerTrust(view, challenge: challenge, prompt: null),
      // A popup is the same site in a dialog, so it presents the same
      // router credential (PROXY-013) and the same saved sign-ins.
      onReceivedHttpAuthRequest: (controller, challenge) =>
          answerHttpAuthChallenge(
            routerIdentity: routerIdentityForConfig(parent),
            session: httpAuth,
            challenge: challenge,
          ),
    );
    return ControllerScope(
      onUnmount: () => view?.markDisposed(),
      child: popup,
    );
  }
}
