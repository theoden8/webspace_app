import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show ServiceWorkerController;

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/diag_seed.dart';
import 'package:webspace/services/site_icon_fetcher.dart' show WpePageIcons;
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/host_user_agent.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/launch_timeline.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/egress_relay.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/licenses.dart';
import 'package:webspace/app.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/keyboard_input.dart';
import 'package:webspace/services/remote_input.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/app_locale.dart';

void main([List<String> args = const []]) async {
  final launch = ProcessLaunch.fromArgs(args);
  LaunchTimeline.start();
  ActivationSteps.sink = (step, {required outcome, required site, required tab}) =>
      LaunchTimeline.stepReached(step);
  WidgetsFlutterBinding.ensureInitialized();

  // Imported HTML files are the only copy of user-supplied content, so they
  // live in their own persistent store and survive upgrades. The page
  // snapshots earlier releases kept beside them go, after any import still
  // among them is carried over.
  Future<void> htmlInit() async {
    await HtmlImportStorage.instance.initialize();
    await HtmlImportStorage.instance.retireSnapshotCache();
  }

  // MaterialApp resolves the platform locale on its first frame (the in-app
  // override is read after it), so reading that ARB here lets the first
  // frame's Localizations complete synchronously instead of holding the frame
  // and the page's startup restore behind an asset read. A different locale
  // later only costs that read.
  Future<void> l10nPreload() => AppLocalizations.delegate.load(
        resolveSupportedLocale(
          WidgetsBinding.instance.platformDispatcher.locales,
          supported: AppLocalizations.supportedLocales,
        ),
      );

  // Disable network loads from any service worker registered by a visited
  // site. Service workers stay alive across page navigations (tied to the
  // origin, not the document), and on Android System WebView there are open
  // chromium regressions where a SW's fetch-handler tasks race against
  // parent-page navigation and trip MiraclePtr's dangling-raw_ptr detector on
  // the IO thread. We never use service-worker functionality ourselves (no
  // offline pages, no push), so blocking SW network is no functional loss.
  Future<void> blockServiceWorkerNetwork() async {
    try {
      await inapp.ServiceWorkerController.setBlockNetworkLoads(true);
      await inapp.ServiceWorkerController.instance()
          .setServiceWorkerClient(null);
      LogTag.webView.debug(
          'Service worker network loads blocked at WebView layer');
    } on PlatformException catch (e) {
      LogTag.webView.error('Failed to block service worker network loads: $e');
    } on MissingPluginException catch (e) {
      LogTag.webView.error('Failed to block service worker network loads: $e');
    }
  }

  // A debug launch may carry a seeded site list (Android intent extra, or
  // WS_DIAG_SEED env for a simctl driver), written before anything reads
  // prefs (INTEG-011/012).
  if (kDebugMode) await DiagSeed.applyFromLaunch();

  // The native interceptor bridge for sub-resource DNS + ABP blocking and
  // LocalCDN serving (Android). The Dart shouldInterceptRequest callback
  // only fires for main-document navigations on modern Chromium WebView,
  // so everything per-subresource goes through the native path.
  final native = WebInterceptNative.initialize();
  // Before the pins load, so a pin the load migrates re-fetches its favicon.
  wireFaviconTrustInvalidation();
  // Until this is installed every TOR request blocks rather than connecting
  // directly: the right failure, but a useless one.
  torProxyResolver = (tag) => TorService.instance.routeFor(siteId: tag.site);
  registerLicenses();

  // Each load starts at once; what needs another's result takes its
  // witness. Every blocker is in before runApp, so blocking stays
  // fail-closed (CB-001).
  final dns = DnsBlockService.instance.initialize();
  final blocker = ContentBlockerService.instance.initialize(native: native);
  await Future.wait([
    htmlInit(),
    PageJs.load(),
    l10nPreload(),
    ClearUrlService.instance.initialize(),
    FirefoxUserAgentService.instance.initialize(),
    HostBrowser.initialize(),
    dns.then((loaded) {
      LaunchTimeline.reached(LaunchMark.dnsLoaded);
      return loaded.mirrorInto(native);
    }),
    blocker.then((loaded) async {
      LaunchTimeline.reached(LaunchMark.blockerLoaded);
      return loaded.seedHostsInto(await dns);
    }),
    LocalCdnService.instance.initialize().then((cdn) => cdn.mirrorInto(native)),
    SiteSearchListService.instance.initialize(),
    BlockStatsService.instance.initialize(),
    if (hostIsAndroid) blockServiceWorkerNetwork(),
    // Proxy support, detected before the UI loads.
    PlatformInfo.initialize(),
    // Whether a TV remote drives the device, read as each webview is built.
    RemoteInput.probe(),
    // Whether a keyboard is attached, followed from here on.
    KeyboardInput.probe(),
    // Where a site's icon comes from on Linux, read as each webview is built.
    WpePageIcons.initialize(),
    // ConnectivityService.lastKnownOnline before the first webview: the
    // offline cached-HTML render path needs a sync answer at construction.
    ConnectivityService.instance.primeLastKnownOnline(),
    // Synchronous callers (flutter_map TileProvider, per-site DEFAULT
    // fallthrough) read GlobalOutboundProxy.current after this.
    GlobalOutboundProxy.initialize(),
    // A site that uses a library entry not loaded yet fails closed until it
    // is.
    ProxyLibrary.initialize(),
    // User-approved TLS exceptions, so a self-signed site trusted in a
    // previous session loads without a prompt, and the Dart-side
    // `badCertificateCallback` sees the same pinned set.
    TrustedHostsService.instance.initialize().then(
      (pins) => pins.resetOnceForOsDefault(),
    ),
    // Read directly by the menus rather than plumbed.
    DeveloperModeService.instance.initialize(),
    ExperimentalFeaturesService.instance.initialize(),
    WebExtensionLibrary.instance.initialize(),
    ExternalTorSettings.initialize(),
  ]);

  // Every load is done from here, so what reads one reads it whole: an
  // experimental switch counts only in developer mode, which loads beside
  // it.
  //
  // A process the OS started for a background task reports a lifecycle
  // other than resumed here, which is how the background log tells a cold
  // wake from a launch the user made.
  BackgroundLog.instance.record(
    LogTag.lifecycle,
    message:
        'process started (app '
        '${WidgetsBinding.instance.lifecycleState?.name ?? 'state not reported yet'})',
  );
  // Before anything touches TorService.instance, which picks its tor from
  // this on first use and on every runtimeChoiceChanged (TOR-025), and on
  // first use reads the Built-in Tor experiment loaded above (TOR-027).
  TorService.wantsExternal = () => ExternalTorSettings.chosen;
  // Before any site's webview: a site bound to an interface resolves to the
  // relay, or to no route while it is not up (NETIF-002).
  await EgressRelay.instance.initialize();
  // A process runs one composition mode, so the Experimental switch applies
  // from the next launch (PAUSE-032).
  WebViewFactory.hybridComposition = !ExperimentalFeaturesService.instance
      .isEnabled(ExperimentalFeature.textureRendering);
  // Before the first webview attaches: what a site's container gives its
  // service workers lasts the process, so this switch too applies from the
  // next launch (CB-022).
  await native.routeServiceWorkers(
      throughBlockers: ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.serviceWorkers));
  // Opt-in weekly Firefox-version auto-refresh (DM-004), left running: a
  // download, so after the proxy, the saved proxies and the choice of tor it
  // may go through (LEAK-004). Preset UAs re-render from the cached version
  // on the next build.
  unawaited(FirefoxUserAgentService.instance.maybeAutoRefresh());
  // Downloads the OS or the user cleared from the cache come back on their
  // own, after the same proxy (PLATFORM-010). A wake's process makes no
  // request the user did not start.
  switch (launch) {
    case ProcessLaunch.user:
      unawaited((await blocker).refetchPurged());
      unawaited((await dns).refetchPurged());
      unawaited(ClearUrlService.instance.refetchPurged());
    case ProcessLaunch.backgroundWake:
      break;
  }
  // Before the restore loads the prefs, so the runner hears the stored value.
  DesktopWindow.instance.start();
  LaunchTimeline.reached(LaunchMark.runApp);
  unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized
      .then((_) => LaunchTimeline.reached(LaunchMark.firstFrame)));
  runApp(WebSpaceApp(launch: launch));
}
