import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show ServiceWorkerController;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/startup_init_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/diag_seed.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/licenses.dart';
import 'package:webspace/app.dart';

/// Debug-only per-step timing for the cold-start critical path. Logs under
/// the 'Startup' tag; compiled out of release builds via kDebugMode. Steps in
/// the concurrent init group overlap and contend on the main isolate, so their
/// reported ms can sum to more than the group wall-clock — read them as
/// "which step is heaviest", not as additive. The serial-tail steps are
/// additive.
Future<void> _runTimed(String label, {required AsyncStep step}) async {
  if (!kDebugMode) return step();
  final sw = Stopwatch()..start();
  try {
    await step();
  } finally {
    LogTag.startup.debug('  $label: ${sw.elapsedMilliseconds}ms');
  }
}

void main([List<String> args = const []]) async {
  launchedForBackgroundWake = args.contains(kBackgroundWakeArg);
  WidgetsFlutterBinding.ensureInitialized();

  final swMain = kDebugMode ? (Stopwatch()..start()) : null;

  // Externally-driven test tiers (INTEG-011/012): a debug launch may
  // carry a seeded site list (Android intent extra, or WS_DIAG_SEED env
  // for a simctl driver); it must land in prefs before the page state
  // reads them.
  if (kDebugMode) {
    await DiagSeed.applyFromLaunch();
  }

  // Imported HTML files are the only copy of user-supplied content, so they
  // live in their own persistent store and survive upgrades. The HTML cache
  // (re-fetchable fetched-page snapshots, safe to drop on upgrade) must
  // initialize after the import store: its pre-wipe hook copies imports left
  // in the legacy cache (from versions before the import store existed) into
  // HtmlImportStorage before they're nuked.
  Future<void> htmlInit() async {
    await HtmlImportStorage.instance.initialize();
    await HtmlCacheService.instance.initialize(
      beforeUpgradeWipe: HtmlImportStorage.migrateFromCache,
    );
  }

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
    } catch (e) {
      LogTag.webView.error('Failed to block service worker network loads: $e');
    }
  }

  // Native interceptor bridge for sub-resource DNS + ABP blocking and LocalCDN
  // serving (Android). The Dart shouldInterceptRequest callback only fires for
  // main-document navigations on modern Chromium WebView, so everything
  // per-subresource goes through the native path. It's the bridgeSetup step:
  // ContentBlockerService.initialize feeds the engine from inside, so the
  // bridge must exist before the parallel group runs.
  //
  // The independent inits touch disjoint storage (each upgrade check keys off
  // its own version pref) and feed independent subsystems, so they overlap
  // rather than run serially. The adblock-rust engine spin-up
  // (ContentBlockerService) and the DNS/timezone dataset loads dominate
  // cold-launch latency; concurrency keeps them off the serial critical path
  // while still completing before runApp, so the fail-closed blocking posture
  // is unchanged. Timezone-polygon lookups are synchronous, so the per-site
  // shim builder needs that data ready before it runs (missing/empty cache is
  // fine — the "From picked location" option just stays disabled).
  final swServices = kDebugMode ? (Stopwatch()..start()) : null;
  await StartupInitEngine.runIndependentInits(
    <AsyncStep>[
      () => _runTimed('html', step: htmlInit),
      () => _runTimed('clearUrl', step: ClearUrlService.instance.initialize),
      () => _runTimed('dns', step: DnsBlockService.instance.initialize),
      () => _runTimed('firefoxUa',
          step: FirefoxUserAgentService.instance.initialize),
      () =>
          _runTimed('adblock', step: ContentBlockerService.instance.initialize),
      () => _runTimed('localCdn', step: LocalCdnService.instance.initialize),
      () => _runTimed('searchList',
          step: SiteSearchListService.instance.initialize),
      () =>
          _runTimed('blockStats', step: BlockStatsService.instance.initialize),
      if (hostIsAndroid)
        () => _runTimed('swBlock', step: blockServiceWorkerNetwork),
    ],
    bridgeSetup: WebInterceptNative.initialize,
  );
  if (swServices != null) {
    LogTag.startup.debug(
        'parallel service init: ${swServices.elapsedMilliseconds}ms');
  }

  // Opt-in weekly Firefox-version auto-refresh (DM-004). Fire-and-forget:
  // a network scrape must never sit on the startup path, and preset UAs
  // re-render from the cached version on the next webview build anyway.
  unawaited(FirefoxUserAgentService.instance.maybeAutoRefresh());

  if (DnsBlockService.instance.hasBlocklist) {
    await _runTimed(
        'dnsSend(${DnsBlockService.instance.domainCount})',
        step: () => WebInterceptNative.sendDnsLevelGroups(
            DnsBlockService.instance.levelGroups));
  }

  // Keep the DNS-side native domain push in sync when the DNS list
  // changes. (Android's native interceptor consumes the raw domains;
  // the iOS/macOS JS prefilter consumes the merged bloom below.)
  DnsBlockService.instance.addBlocklistChangedListener(() {
    WebInterceptNative.sendDnsLevelGroups(DnsBlockService.instance.levelGroups);
  });
  ContentBlockerService.instance.addRulesChangedListener(() {
    // Feed the ABP `||host^` block hosts into the merged prefilter Bloom
    // so the iOS/macOS interceptor trips for ABP-only hosts instead of
    // hard-allowing them on a bloom miss. Also invalidates the bloom.
    DnsBlockService.instance.setAbpNetworkHosts(
        ContentBlockerService.instance.abpNetworkBlockHosts);
  });
  // Seed the merged bloom with the ABP hosts harvested by the initial
  // engine build — that build ran during init, before the listener
  // above existed, so its rules-changed notification was not delivered.
  DnsBlockService.instance.setAbpNetworkHosts(
      ContentBlockerService.instance.abpNetworkBlockHosts);

  await _runTimed(
      'cdnSend',
      step: () async {
        await WebInterceptNative.sendCdnPatterns(
            LocalCdnService.instance.cdnPatternStrings);
        await WebInterceptNative.sendCdnCacheIndex(
            LocalCdnService.instance.cacheIndexSnapshot);
      });
  LocalCdnService.instance.addCacheChangeListener(() {
    WebInterceptNative.sendCdnCacheIndex(
        LocalCdnService.instance.cacheIndexSnapshot);
  });

  registerLicenses();

  // Initialize platform info to detect proxy support before UI loads
  await _runTimed('platformInfo', step: PlatformInfo.initialize);

  // Prime ConnectivityService.lastKnownOnline before the first webview
  // is constructed. The offline cached-HTML render path needs a sync
  // answer to decide between live URL and `initialData` at construction
  // time — without this the first webview always sees `null` and
  // defaults to live load even when the device is offline.
  await _runTimed(
      'connectivity', step: ConnectivityService.instance.primeLastKnownOnline);

  // HTML caches are not bulk-preloaded here: that would decrypt every
  // cached + imported page (e.g. a 9.7 MB notif import) before the first
  // frame, even when the launched site needs none of them. Instead each site's
  // page is decrypted on demand via `HtmlCacheService.preloadOne` /
  // `HtmlImportStorage.preloadOne` right before it enters `_sites.loaded`
  // (in `_setCurrentIndex` and the deferred notification-site load), so the
  // build's synchronous `getHtmlSync` still hits but only for sites that
  // actually build.

  // Load the global outbound proxy from SharedPreferences. Synchronous
  // callers (flutter_map TileProvider, per-site DEFAULT fallthrough) read
  // GlobalOutboundProxy.current after this.
  await _runTimed('proxyInit', step: GlobalOutboundProxy.initialize);
  // Before any site resolves a proxy: a site that uses a library entry that
  // has not loaded yet fails closed until it does.
  await _runTimed('proxyLibraryInit', step: ProxyLibrary.initialize);
  // Teach the outbound seams how to expand ProxyType.TOR. Until this is
  // installed every TOR request blocks rather than connecting directly,
  // which is the right failure but a useless one, so install it early —
  // before any site can build a webview or fetch a favicon.
  torProxyResolver = (tag) => TorService.instance.socksFor(
        siteId: tag == kTorAppGlobalTag ? null : tag,
      );
  // Hydrate user-approved TLS exceptions so a self-signed site the user
  // already trusted in a previous session loads without a prompt — and
  // so the Dart-side `HttpClient.badCertificateCallback` (favicon
  // probes, downloads, …) sees the same pinned set.
  await TrustedHostsService.instance.initialize();
  // Gate for diagnostic-only affordances; read directly by the menus rather
  // than plumbed, so it must be hydrated before the first frame.
  await DeveloperModeService.instance.initialize();
  // A process the OS started for a background task reports a lifecycle other
  // than resumed here, which is how the background log tells a cold wake from
  // a launch the user made.
  BackgroundLog.instance.record(
    LogTag.lifecycle,
    message: 'process started (app '
        '${WidgetsBinding.instance.lifecycleState?.name ?? 'state not reported yet'})',
  );
  await ExperimentalFeaturesService.instance.initialize();
  // Before anything touches TorService.instance, which picks its tor from
  // this on first use and on every runtimeChoiceChanged (TOR-025).
  await ExternalTorSettings.initialize();
  TorService.wantsExternal = () =>
      externalTorRunsHere &&
      ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.externalTor);
  // Before any webview exists, and only here: a process runs one composition
  // mode, so the Experimental switch applies from the next launch (PAUSE-032).
  WebViewFactory.hybridComposition = !ExperimentalFeaturesService.instance
      .isEnabled(ExperimentalFeature.textureRendering);
  // Re-fetch favicons whose initial request died on
  // CERTIFICATE_VERIFY_FAILED once the user later approves the cert
  // via the webview trust prompt. Subscribes before any pin can fire,
  // so even an immediate trust on first launch is observed.
  wireFaviconTrustInvalidation();
  // One-shot reset: the initial release of the trust prompt
  // (commit 5ef1174) intercepted every TLS handshake on iOS/macOS
  // because the Dart handler short-circuited Apple Keychain
  // validation. Users ended up pinning leaf fingerprints for dozens
  // of valid public CA sites. Clear those pins once so the new
  // OS-default-first flow has a clean slate; legitimate self-signed
  // pins (the only ones a user would have wanted) get re-prompted on
  // next visit.
  {
    final prefs = await SharedPreferences.getInstance();
    const resetKey = 'trustedHostsResetForOsDefaultV1';
    if (!(prefs.getBool(resetKey) ?? false)) {
      await TrustedHostsService.instance.clear();
      await prefs.setBool(resetKey, true);
    }
  }
  if (swMain != null) {
    LogTag.startup.debug(
        'main() pre-runApp init: ${swMain.elapsedMilliseconds}ms');
  }
  runApp(WebSpaceApp());
}
