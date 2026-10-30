import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/http_auth_challenge.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/webview_tls.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/page_scripts.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/page_phase.dart';
import 'package:webspace/services/screen_share.dart';
import 'package:webspace/services/view_key.dart';
import 'package:webspace/services/webview.dart';

/// What a window a site's page asked for is opened for, when the app shows
/// it as a real popup: the page keeps its handle on the window, so what the
/// popup posts back reaches it. Any other window request is decided as a
/// navigation (NESTED-001).
enum PopupKind {
  /// A captcha challenge (CAPTCHA-010).
  verification,

  /// A sign-in on an identity provider's own host, where the site's Sign-in
  /// popups switch is on (NESTED-014).
  signIn;

  /// Whether this host opens sign-in windows only with the Sign-in popups
  /// experiment on (DEVTOOLS-011): Android. Everywhere else they graduated.
  static bool get signInExperimental =>
      debugSignInExperimental ?? hostIsAndroid;

  /// Lets a test run either rule whatever its host.
  @visibleForTesting
  static bool? debugSignInExperimental;

  /// Whether this host opens sign-in windows as popups at all, so the app's
  /// and each site's Sign-in popups switches apply.
  static bool get signInOffered =>
      !signInExperimental ||
      ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.signInPopups);

  /// Whether a site webview built now opens sign-in windows as popups, by the
  /// site's [choice] or, while it follows the app, the app's.
  static bool signInOpens({required Scoped<bool> choice}) =>
      signInOffered && choice.resolve(AppPref.signInPopups.value);

  /// Identity providers' sign-in hosts, each with its subdomains.
  static const _signInHosts = [
    'accounts.google.com',
    // Google's sign-in sets its session on YouTube by redirecting through it.
    'accounts.youtube.com',
    'appleid.apple.com',
    'login.microsoftonline.com',
    'login.live.com',
    'github.com',
  ];

  static bool isSignInUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return _signInHosts
        .any((h) => uri.host == h || uri.host.endsWith('.$h'));
  }

  /// The popup a window request for [url] by the site at [siteUrl] opens, or
  /// null for none. With [signInPopups] (the site's [signInOpens]), the
  /// engine only asks for a window the user's tap opened (NESTED-014);
  /// Android names no URL for one a script opened, so that one opens as a
  /// sign-in popup and its own rule ([showsOffSite]) judges its first page.
  static PopupKind? forWindow(String url,
      {required String siteUrl, required bool signInPopups}) {
    if (WebViewFactory.isCaptchaChallenge(url, siteUrl: siteUrl)) {
      return PopupKind.verification;
    }
    if (signInPopups && (url.isEmpty || isSignInUrl(url))) return signIn;
    return null;
  }

  /// Whether this popup may show [url], off the site at [siteUrl], as its
  /// top document.
  bool showsOffSite(String url, {required String siteUrl}) =>
      WebViewFactory.isCaptchaChallenge(url, siteUrl: siteUrl) ||
      switch (this) {
        PopupKind.verification => false,
        PopupKind.signIn => isSignInUrl(url),
      };
}

/// The webview that asked for a popup window: its config, and its
/// controller, which the popup goes quiet with (PROXY-008).
typedef PopupParent = ({WebViewConfig config, PlatformWebViewController? opener});

/// The webview a site's `window.open` gets, built from its parent's posture.
abstract final class PopupWebView {
  /// The webview that asked for a popup window, keyed by the `windowId` the
  /// host UI is handed. The host builds the popup widget from a
  /// `BuildContext` that knows nothing about the site, so the parent's
  /// posture would otherwise be lost between `onCreateWindow` and
  /// [createPopupWebView] — and a popup with no shims, no container and no
  /// proxy is a hole straight through every per-site setting.
  static final Map<int, PopupParent> popupParents = {};

  /// Create a popup webview for handling window.open() calls.
  /// Used for Cloudflare challenges and other popups that require a real window.
  ///
  /// [config] defaults to the parent webview's, recorded when the popup was
  /// requested. The popup inherits its identity (UA, shims, user scripts),
  /// its store binding and its proxy: it is the same site, in a dialog.
  static Widget createPopupWebView({
    required int windowId,
    required PopupKind kind,
    WebViewConfig? config,
    VoidCallback? onCloseWindow,
  }) {
    final opener = popupParents[windowId]?.opener;
    final parent = config ?? popupParents[windowId]?.config;
    if (parent == null) {
      // No parent posture to inherit means we cannot tell what the popup is
      // allowed to be. Render nothing rather than a fully-privileged webview.
      return const SizedBox.shrink();
    }
    final binding = WebViewFactory.bindingFor(parent);
    // Same fail-closed rule as the site webview: a proxy the site expects but
    // the platform cannot honor must not become a direct connection.
    if (binding.proxyUnavailable || binding.relayDown) {
      return const SizedBox.shrink();
    }
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
    Object? attachedView;
    ViewKey? shareView;
    // A popup decides for itself as a nested screen does: a page in it is
    // not the one the user answered for the site, so a remembered `real`
    // goes back to asking and an answer given here stays here (SHARE-014,
    // CAM-005, MIC-005). It is on screen while its opener's site is.
    final siteGrants = parent.grants;
    final grants = siteGrants == null
        ? null
        : InMemoryGrantStore(
            parent.posture.forNested().media,
            prompter: parent.hooks.media,
            isSiteActive: siteGrants.isSiteActive,
          );
    // The popup's documents, which a script its handlers evaluate lands in.
    final phases = PagePhases(
      blocking: parent.posture.blocking,
      dnsLevel: () => parent.effectiveDnsLevel,
    );
    var started = false;
    final popup = inapp.InAppWebView(
      windowId: windowId,
      initialSettings: settings,
      initialUserScripts: UnmodifiableListView(page.userScripts),
      onWebViewCreated: (controller) {
        phases.on(PageEvent.viewCreated, view: controller.platform);
        // The opener drives the popup's first load, so it cannot be held;
        // the interceptor attaches as soon as the view exists.
        // It is one of the site's views, told its level as the lists move
        // (DNS-022).
        final viewId = controller.getViewId();
        if (WebInterceptNative.isSupported && viewId != null) {
          attachedView = viewId as Object;
          unawaited(WebInterceptNative.attachToView(
            DnsBlockService.instance.views.built(
              viewId,
              site: parent.posture.siteId,
              siteLevel: parent.siteDnsAsk,
              localCdn: parent.posture.blocking.localCdn,
              contentBlock: parent.posture.blocking.contentBlock,
            ),
          ));
        }
        // A view made again replaces the one its opener holds, which would
        // otherwise be closed twice.
        if (view case final previous?) opener?.disown(previous);
        final popupView = view = PlatformWebViewController(controller,
            pauseHack: PauseTimersHackState(),
            settings: settings,
            loadsAfter: Future<void>.value(),
            refuses: (url) =>
                WebViewFactory.refusesLoad(binding, url: url) != null,
            navigationHeaders: WebViewFactory.navigationHeaders(parent));
        opener?.adopt(popupView, close: () => onCloseWindow?.call());
        shareView = ViewKey.of(controller);
        PageHandlers.registerPageHandlers(
          controller,
          config: parent,
          grants: grants,
          userScriptService: page.userScriptService,
          page: (
            sourceUrl: () => parent.initialUrl,
            document: () => phases.page(controller),
          ),
        );
      },
      onLoadStart: (controller, _) {
        started = true;
        phases.on(PageEvent.loadStarted, view: controller.platform);
        unawaited(ScreenShare.instance.endView(ViewKey.of(controller)));
      },
      // The popup exists for one flow: its documents pass the site's DNS and
      // content-blocker checks, and its top document stays on the site's own
      // domain or a host its kind allows (CAPTCHA-010, NESTED-014). One whose
      // first page is refused has nothing to show, so it closes.
      shouldOverrideUrlLoading: (_, navigationAction) async {
        final policy = WebViewFactory.onSiteNavigationPolicy(parent,
            navigationAction: navigationAction, popup: kind);
        if (policy == inapp.NavigationActionPolicy.CANCEL && !started) {
          onCloseWindow?.call();
        }
        return policy;
      },
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
      onUnmount: () {
        phases.unmounted();
        if (shareView case final key?) {
          unawaited(ScreenShare.instance.endView(key));
        }
        if (view case final popupView?) opener?.disown(popupView);
        view?.markDisposed();
        if (attachedView case final id?) DnsBlockService.instance.views.gone(id);
      },
      child: popup,
    );
  }
}
