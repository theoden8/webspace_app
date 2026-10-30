/// Where a site's proxy is actually enforced on this platform (PROXY-027).
///
/// The app has always had two shapes for this and picked between them by
/// platform name at each call site. Neither is a property of the operating
/// system: it is a property of what the engine binds a proxy to, which is
/// why it gets a name of its own.
enum ProxyBinding {
  /// The site's own network store carries the proxy, so sites with
  /// different proxies stay loaded at the same time.
  perSite,

  /// One process-wide rule names the loopback relay, which sends each site
  /// to its own upstream by the credential its profile presents
  /// (PROXY-013), so sites with different proxies stay loaded at the same
  /// time. A proxied site that the relay cannot route does not load.
  routed,

  /// One process-wide rule carries the site's own proxy. Sites whose
  /// effective proxies differ cannot be loaded together; activation
  /// disposes the ones that disagree before the rule flips (PROXY-008).
  processWide,
}

/// Pure decision for [ProxyBinding]. Free of platform reads so the cases
/// are assertable off the platform that produces them -- on a Linux test
/// host `hostIsMacOS` answers false first and every further assertion
/// passes without meaning it.
class ProxyBindingEngine {
  /// Apple binds a proxy through `WKWebsiteDataStore.proxyConfigurations`,
  /// which the app sets per container store. Linux binds it per
  /// `WebKitNetworkSession`: a container's session, or an incognito
  /// webview's ephemeral one, holds its own, and the process-wide override
  /// leaves it alone. Every Linux build has those sessions, since the fork's
  /// Linux plugin needs WPE 2.40+ to compile and lists Linux as a container
  /// platform; older WPE is not supported. Elsewhere the proxy is one
  /// process-wide rule: Android's `ProxyController`. Where the restore
  /// found per-site profiles ([androidContainers]) that rule names the
  /// relay for the whole run; without them every site shares one network
  /// session and one cached proxy credential, so the relay could not tell
  /// them apart and the rule names the site's own proxy.
  ///
  /// This is deliberately ungated. An earlier version of this decision put
  /// the Apple per-store path behind developer mode, because the belief
  /// then was that only one store is honoured per process and shipping it
  /// would be a silent leak. BUG-014 attempts 80 and 90 measured several
  /// stores reaching several upstreams at once, so the gate guarded
  /// nothing and cost every Apple user their per-site proxy.
  static ProxyBinding bindingWhen({
    required bool isIOS,
    required bool isMacOS,
    required bool isLinux,
    required bool androidContainers,
  }) {
    if (isIOS || isMacOS || isLinux) return ProxyBinding.perSite;
    if (androidContainers) return ProxyBinding.routed;
    return ProxyBinding.processWide;
  }
}
