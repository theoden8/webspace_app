/// Where a site's proxy is actually enforced on this platform (PROXY-020).
///
/// The app has always had two shapes for this and picked between them by
/// platform name. Neither is a property of the operating system: it is a
/// property of what the engine binds a proxy to, which is why it gets a
/// name of its own rather than another `hostIsX` at every call site.
enum ProxyBinding {
  /// The site's own network store carries the proxy, so sites with
  /// different proxies stay loaded at the same time.
  perSite,

  /// One process-wide rule carries it. Sites whose effective proxies
  /// differ cannot be loaded together; activation disposes the ones that
  /// disagree before the rule flips (PROXY-008).
  processWide,
}

/// Pure decision for [ProxyBinding]. Free of platform reads so the negative
/// cases are assertable off the platform that produces them.
class ProxyBindingEngine {
  /// Apple binds a proxy through `WKWebsiteDataStore.proxyConfigurations`,
  /// which the app can set per container store. Only one of those stores is
  /// honoured per process (BUG-014), so a second proxied site loads over the
  /// device IP while the Dart side believes it is proxied. Shipping that as
  /// the default would be a silent leak, so the default on Apple is the
  /// process-wide rule the fork's `setProxyOverride` fans out to every
  /// store, with PROXY-008 serialisation on top: one proxy in force, and any
  /// site that disagrees is unloaded rather than left to go direct.
  ///
  /// [developerMode] selects the per-store path instead. It is off by
  /// default and the people who turn it on are the ones who can read
  /// `LogService` when a site goes direct.
  static ProxyBinding bindingWhen({
    required bool isIOS,
    required bool isMacOS,
    required bool developerMode,
  }) =>
      (isIOS || isMacOS) && developerMode
          ? ProxyBinding.perSite
          : ProxyBinding.processWide;
}
