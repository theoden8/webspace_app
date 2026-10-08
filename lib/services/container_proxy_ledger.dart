/// The containers this process gave a proxy of their own (PROXY-029).
///
/// The fork keeps a container's proxy for the rest of the process once a
/// WebView is built on it naming one, and a WebView built naming none leaves
/// it in force. Only `ProxyController.clearProxyOverride(containerId:)` takes
/// it off, so the app has to remember which containers need that when their
/// site stops naming a proxy.
///
/// Errs toward clearing: a build that never mounts leaves an entry whose
/// clear finds nothing, which costs one deferred first load.
class ContainerProxyLedger {
  /// Builds with a proxy per container. A count rather than a flag so a
  /// build that lands while a clear is in flight is not forgotten when the
  /// clear returns.
  final Map<String, int> _builds = {};

  bool holds(String containerId) => _builds.containsKey(containerId);

  /// A WebView is being built on [containerId] with a proxy of the site's
  /// own. Either null records nothing.
  void noteBuild(String? containerId, {required Object? proxy}) {
    if (containerId == null || proxy == null) return;
    _builds.update(containerId, (n) => n + 1, ifAbsent: () => 1);
  }

  /// Take [containerId]'s proxy off through [clear]. A failed clear keeps
  /// the entry, so the next build of the site asks again.
  Future<void> release(
    String containerId, {
    required Future<void> Function(String containerId) clear,
  }) async {
    final buildsAtEntry = _builds[containerId];
    await clear(containerId);
    if (_builds[containerId] == buildsAtEntry) _builds.remove(containerId);
  }

  /// Whether a WebView about to be built must first have its container's
  /// proxy cleared.
  ///
  /// [siteNamesProxy]: the site stated what its proxy is (DEFAULT included).
  /// A caller that states nothing leaves the container as it is.
  /// [boundProxy]: the build carries a proxy, which replaces the old one.
  /// [proxyUnavailable]: the page stays blank, and an old proxy is still a
  /// proxy, so nothing is cleared.
  bool mustRelease({
    required bool bindsProxyPerSite,
    required String? containerId,
    required bool siteNamesProxy,
    required bool boundProxy,
    required bool proxyUnavailable,
  }) =>
      bindsProxyPerSite &&
      containerId != null &&
      siteNamesProxy &&
      !boundProxy &&
      !proxyUnavailable &&
      holds(containerId);
}
