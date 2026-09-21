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

  /// One process-wide rule carries it. Sites whose effective proxies
  /// differ cannot be loaded together; activation disposes the ones that
  /// disagree before the rule flips (PROXY-008).
  processWide,
}

/// Pure decision for [ProxyBinding]. Free of platform reads so the cases
/// are assertable off the platform that produces them -- on a Linux test
/// host `hostIsMacOS` answers false first and every further assertion
/// passes without meaning it.
class ProxyBindingEngine {
  /// Apple binds a proxy through `WKWebsiteDataStore.proxyConfigurations`,
  /// which the app sets per container store. Everywhere else the proxy is
  /// one process-wide rule: Android's `ProxyController`, and Linux's
  /// default `WebKitNetworkSession` for a site with no container.
  ///
  /// Router mode (PROXY-013) is not a third value. It changes what the
  /// rule *names* -- the loopback relay rather than the site's upstream --
  /// and not where the rule lives, so it rides whichever binding is in
  /// force rather than replacing it.
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
  }) =>
      isIOS || isMacOS ? ProxyBinding.perSite : ProxyBinding.processWide;
}
