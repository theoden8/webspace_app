import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_router_probe.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// Where the sites' traffic goes and what a change to it does to them: the
/// proxy topology and the router's routes (PROXY-008, PROXY-013), the Tor
/// runtime's holders and exit pin (TOR-002, TOR-014), Tor endpoint changes
/// (TOR-008), and revoking a pinned certificate.
class SiteNetworkController {
  SiteNetworkController(
    this._sites,
    this._host, {
    required this.residency,
    required this.background,
    required this.containers,
  });

  final SiteRuntime _sites;
  final PageHost _host;
  final ResidencyHost residency;
  final BackgroundSitesController background;
  final ContainerIsolationEngine containers;

  StreamSubscription<TrustedHostEntry>? _untrustSub;
  StreamSubscription<TorStatus>? _torStatusSub;
  TorStatus _lastTorStatus = const TorStopped();

  void start() {
    // A revoked pin takes effect at once: the rendered webview would keep
    // showing the cached DOM, and its reload may come from the HTTP cache
    // without a fresh TLS handshake. The wiped site reloads, the trust
    // callback finds no pin, and the prompt fires again.
    _untrustSub = TrustedHostsService.instance.untrustChanges.listen(pinRevoked);
    // A TOR-bound webview computes its proxy binding once, when it is built
    // (`_bindingFor` is synchronous), so one built during bootstrap would
    // stay bound to a null SOCKS endpoint and load the site direct (TOR-008).
    // Every TOR-bound webview is disposed whenever the endpoint it would bind
    // to changes; a restart comes back on another loopback port.
    _lastTorStatus = TorService.instance.status;
    _torStatusSub = TorService.instance.statusStream.listen(_torStatusChanged);
  }

  void dispose() {
    _untrustSub?.cancel();
    _torStatusSub?.cancel();
  }

  void _torStatusChanged(TorStatus s) {
    if (!_host.mounted) return;
    if (!torBindingChanged(_lastTorStatus, s)) return;
    _lastTorStatus = s;
    var anyTorSite = false;
    for (final m in _sites.models) {
      if (resolveEffectiveProxy(m.proxySettings, siteId: m.siteId).type !=
          ProxyType.TOR) {
        continue;
      }
      anyTorSite = true;
      // A site with no webview shows the placeholder; the rebuild below
      // builds the real one.
      if (m.webview != null) m.disposeWebView();
    }
    if (!anyTorSite) return;
    // Router mode encodes a Tor route against the endpoint it saw last
    // (PROXY-016), so a new one, or none, has to reach the route table too.
    unawaited(refreshRoutes());
    _host.rebuild();
  }

  /// Revoking a pinned certificate wipes what its host's sites remembered of
  /// the handshake, so their next load asks again.
  Future<void> pinRevoked(TrustedHostEntry entry) async {
    LogService.instance.log(
      'TLS',
      'pin revoked for ${entry.host}:${entry.port} '
          '(loaded=${_sites.loaded.toList()..sort()}, '
          'webViewModels=${_sites.models.length})',
      sensitivity: LogSensitivity.sensitive,
    );
    final host = entry.host.toLowerCase();
    // Android's cert-acceptance state lives in multiple layers:
    //   1. App-level SSL preferences table (WebView.clearSslPreferences) —
    //      where `handler.proceed()` decisions are kept. Doc-claimed
    //      shared across WebViews; we call on the matching host's
    //      controller first if available since some Android versions
    //      key this per-instance despite docs.
    //   2. Chromium network-service HTTP cache + connection pool —
    //      nuked by `InAppWebViewController.clearAllCache(includeDiskFiles: true)`,
    //      a static call that flushes the process-shared cache.
    //   3. Per-site container storage (cookies, localStorage, IDB, SW,
    //      service-worker registrations) — wiped in the loop below.
    // We hit all three because empirically just (1)+(3) doesn't stop
    // the network service from reusing a remembered "trusted" verdict.
    WebViewController? matching;
    WebViewController? anyLive;
    for (final i in _sites.loaded) {
      if (i >= _sites.models.length) continue;
      final m = _sites.models[i];
      final c = m.controller;
      if (c == null) continue;
      anyLive ??= c;
      if (_pinnedBy(m, host, entry.port)) matching ??= c;
    }
    final preferred = matching ?? anyLive;
    if (preferred != null) {
      try {
        await preferred.nativeController.clearSslPreferences();
        LogService.instance.log(
          'TLS',
          'clearSslPreferences() completed for ${entry.host}:${entry.port} '
              '(via ${matching != null ? "matching-host" : "any-loaded"} controller)',
          sensitivity: LogSensitivity.sensitive,
        );
      } catch (e) {
        LogService.instance.log('TLS',
            'clearSslPreferences() failed: $e',
            level: LogLevel.error);
      }
    } else {
      LogService.instance.log(
        'TLS',
        'no loaded controller to call clearSslPreferences() for '
            '${entry.host}:${entry.port} — SSL prefs table may retain stale '
            'host decisions until next app restart',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    // Static: flushes the Chromium network service every WebView and
    // profile shares.
    try {
      await inapp.InAppWebViewController.clearAllCache(includeDiskFiles: true);
      LogService.instance.log(
        'TLS',
        'clearAllCache(disk=true) completed for revoke of '
            '${entry.host}:${entry.port}',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (e) {
      LogService.instance.log('TLS',
          'clearAllCache failed: $e',
          level: LogLevel.error);
    }
    if (!_host.mounted) return;
    var changed = false;
    final wipedSiteIds = <String>[];
    for (var i = 0; i < _sites.models.length; i++) {
      final model = _sites.models[i];
      if (!_pinnedBy(model, host, entry.port)) continue;
      HtmlCacheService.instance.deleteCache(model.siteId);
      // Outside the unload funnel on purpose: the session is wiped so the
      // next load re-handshakes (BUG-025).
      if (_sites.loaded.contains(i)) {
        model.disposeWebView();
        _sites.loaded.remove(i);
        background.noteUnloaded(model, 'certificate trust revoked');
        changed = true;
      }
      wipedSiteIds.add(model.siteId);
    }
    // `WebView.clearSslPreferences()` clears the app-level table of
    // user "proceed" decisions but does NOT clear the network
    // service's per-host TLS state — once the network process has
    // accepted a cert during the original handshake, subsequent
    // connections to the same host reuse that decision via the
    // connection pool / TLS session cache, never re-firing
    // `onReceivedSslError`. Clearing the per-site container drops the
    // network service's session state for those hosts along with
    // cookies/localStorage/IndexedDB — acceptable for self-signed
    // hosts where the user has no meaningful session, and the in-app
    // pin had to be approved again for the site to load anyway.
    if (wipedSiteIds.isNotEmpty) {
      var cleared = 0;
      for (final siteId in wipedSiteIds) {
        if (await containers.clearForSite(siteId)) cleared++;
      }
      LogService.instance.log(
        'TLS',
        'cleared $cleared of ${wipedSiteIds.length} container(s) after '
            'revoke of ${entry.host}:${entry.port}',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    if (changed && _host.mounted) _host.rebuild();
  }

  /// Whether [model]'s home is the pinned [host] and [port].
  static bool _pinnedBy(WebViewModel model, String host, int port) {
    final uri = Uri.tryParse(model.initUrl);
    if (uri == null || uri.host.toLowerCase() != host) return false;
    final sitePort = uri.hasPort
        ? uri.port
        : (uri.scheme == 'https' ? 443 : (uri.scheme == 'http' ? 80 : 0));
    return sitePort == port;
  }

  /// Reconcile the Tor runtime's refcount with the sites that actually want
  /// it right now (TOR-002).
  ///
  /// A whole-set sync rather than per-toggle acquire/release calls: every
  /// path that can change the answer — editing a site, importing settings,
  /// deleting a site, flipping the global proxy — already funnels through
  /// here, and computing a delta at each of those call sites is how a
  /// deleted site ends up pinning the runtime up forever.
  Future<void> syncTorHolders() async {
    final holders = <TorHolder>{
      for (final m in _sites.models)
        if (m.proxySettings.type == ProxyType.TOR) TorSiteHolder(m.siteId),
      if (GlobalOutboundProxy.current.type == ProxyType.TOR)
        const TorAppWideHolder(),
    };
    await TorService.instance.syncHolders(holders);
    // Clearing a site's pin in settings never re-activates it, so without
    // this the country the user just removed would stay applied until the
    // next site switch. The site on screen wins, then the most recently
    // used; a saved change can leave two loaded sites wanting different
    // pins, and the one that loses is unloaded before the pin moves, as
    // activation does, or it is rebuilt under a country it never chose.
    final order = <int>{?_sites.current, ..._sites.loaded.toList().reversed};
    final plan = SiteUnloadEngine.plan(residency, TorExitSettled(order));
    await SiteUnloadEngine.apply(residency, plan,
        isStale: () => !_host.mounted);
    if (plan.unloads.isNotEmpty && _host.mounted) _host.rebuild();
    syncTorExitPin(order);
  }

  /// Put in force the exit pin the sites in [pinned] want (TOR-014),
  /// without waiting for it.
  ///
  /// Nothing here may wait: the change is a control-port round trip, and a
  /// control socket iOS reclaimed while the app slept never answers. When
  /// the activation path awaited it, every tap on a site did nothing
  /// (BUG-018). Waiting is not needed either: the engine holds every
  /// Tor-bound site behind the interstitial from this call until the pin
  /// lands, and bounds the round trip itself.
  void syncTorExitPin(Set<int> pinned) {
    unawaited(TorService.instance.setExitCountry(
      SiteUnloadEngine.torExitNodesFor(
          indices: pinned, models: _sites.slotIdentities()),
      mayFetchGeoIp: !SiteUnloadEngine.torExitPinIsArchiveOnly(
          indices: pinned, models: _sites.slotIdentities()),
    ));
  }

  /// How a proxy is scoped on this host right now (PROXY-008, PROXY-013).
  /// Linux has no router. A site without a container profile runs in the
  /// default one, so under the router it still shares a cached credential.
  ProxyTopology get topology {
    if (hostIsLinux) return const ProcessGlobalProxy();
    if (ProxyRouterService.instance.isActive) {
      return RoutedProxy((m) => !ownsContainerProfile(m));
    }
    return hostIsAndroid ? const ProcessGlobalProxy() : const PerSessionProxy();
  }

  /// Whether [model] gets a container profile, and so a Chromium network
  /// session, of its own.
  bool ownsContainerProfile(WebViewModel model) => siteOwnsContainerProfile(
        containersSupported: _sites.useContainers,
        containerSiteIdentifier: model.archiveContainerId ?? model.siteId,
        incognito: model.effectiveIncognito,
      );

  /// Per-site proxies as the router's route table sees them, keyed by
  /// routing identity rather than by site.
  ///
  /// A site with its own container profile is its own identity. The rest
  /// -- incognito, and archive-tier which is always incognito -- share the
  /// default profile and therefore one cached proxy credential, so they
  /// share one identity whose upstream follows whichever of them is
  /// active. Giving them a credential each would let one cached by a site
  /// that has since unloaded route the next site to load, straight through
  /// the wrong upstream.
  ///
  /// Archive-tier sites are routed like any other: they render like one
  /// and their traffic still has to reach the right upstream. Only their
  /// *persistence* is partitioned (ARCH-001), and no route is written to
  /// disk.
  Map<String, UserProxySettings> _routeTable({int? activeIndex}) =>
      ProxyRouterEngine.routeTable(
        sites: [
          for (final m in _sites.models)
            RouterSite(
              siteId: m.siteId,
              proxy: m.proxySettings,
              ownsContainer: ownsContainerProfile(m),
            ),
        ],
        sharedProfilePriority: [
          ?activeIndex,
          ?_sites.current,
          ..._sites.loaded,
        ],
      );

  /// Bring up the per-site proxy router (PROXY-013).
  ///
  /// Failure at any step leaves `ProxyRouterService.isActive` false, which
  /// puts every downstream branch back on the PROXY-008 serialisation —
  /// the pre-router behaviour, which is correct, just slower on switch.
  /// Nothing here may clear the proxy override on failure.
  Future<void> activateRouter() async {
    if (!ProxyRouterService.isSupported(useContainers: _sites.useContainers)) {
      return;
    }
    // Apple has no process-wide rule to bind: each container store names the
    // relay through its own `proxyConfigurations` when the WebView is built
    // (PROXY-026), which is already true by the time the probe runs because
    // `activate` publishes the endpoint before probing. Passing a binder
    // that answers false off Android would stand router mode down on the one
    // platform that does not need one.
    final bindsProcessWide = hostIsAndroid;
    await ProxyRouterService.instance.activate(
      perSiteProxies: _routeTable(),
      bindOverride: bindsProcessWide ? ProxyManager().applyRouterOverride : null,
      // PROXY-015: never trust router mode without proving on THIS device
      // that each container presents its own credential.
      probe: runAttributionProbe,
    );
    // A null return stands the router down but never clears the override:
    // the `_setCurrentIndex` that follows re-applies the site's PROXY-008
    // proxy, and until it does a dead relay port fails closed.
  }

  /// Re-install routes after sites, proxies, or the global proxy changed.
  ///
  /// [activeIndex] names the site about to be activated, so the
  /// shared-profile identity is repointed before that site's first
  /// request rather than after it.
  Future<void> refreshRoutes({int? activeIndex}) async {
    if (!ProxyRouterService.instance.isActive) return;
    await ProxyRouterService.instance.refreshRoutes(
        perSiteProxies: _routeTable(activeIndex: activeIndex));
  }
}
