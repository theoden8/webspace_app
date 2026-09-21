import 'package:webspace/services/proxy_binding_engine.dart';

/// Whether a navigation a proxied site is about to issue can be shown to go
/// through that proxy (LEAK-010).
enum ProxyCoverage {
  /// The site runs on DEFAULT with no global proxy behind it, so no claim
  /// about a proxy is being made and nothing has to be established.
  notClaimed,

  /// The request is bound to the proxy the user configured.
  established,

  /// The app cannot establish that the request would be proxied. This is not
  /// "the proxy is down" and not "the request failed": nothing was sent.
  unprovable,
}

/// Decides [ProxyCoverage] for one navigation.
///
/// Pure, and free of platform reads, so the Apple case is assertable on a
/// Linux test host -- the mistake PROXY-027 was written to stop.
class ProxyCoverageEngine {
  /// [isMountNavigation] is the navigation issued in the frame that mounts
  /// the WebView, which is the one the store's proxy is applied to.
  ///
  /// Under [ProxyBinding.processWide] the rule sits outside the WebView and
  /// catches every request it makes, so mount and post-mount navigations are
  /// alike. Under [ProxyBinding.perSite] the proxy is written onto
  /// `WKWebsiteDataStore.proxyConfigurations` at construction, and BUG-014
  /// attempts 90 and 92 measured, twice and each against a live control in
  /// the same process, that it covers the navigation issued in the turn that
  /// mounted the WebView and nothing after it (`sameturn-loadurl=proxied`
  /// against `persist-loadurl=DIRECT`, the same `loadUrl` on the same
  /// controller). Attempt 91 adds that CONNECT fails identically to SOCKS5,
  /// so a loopback relay does not escape it.
  ///
  /// [ProxyCoverage.established] for a mounting navigation is the claim the
  /// app already makes when it binds a store (PROXY-027), not a stronger one
  /// made here: those same runs read `later-pair=0 of 2 proxied` for stores
  /// built after the app's first frame. Nothing may be built on top of it --
  /// in particular, reopening a refused destination on a fresh view is not a
  /// proxied path and is not offered as one.
  ///
  /// Linux is per-site in the other sense and is deliberately not a case
  /// here: it carries the proxy on a `WebKitNetworkSession` the container
  /// owns, which the whole session's traffic goes through. PROXY-027 already
  /// calls that binding process-wide.
  static ProxyCoverage coverageFor({
    required ProxyBinding binding,
    required bool proxyConfigured,
    required bool isMountNavigation,
  }) {
    if (!proxyConfigured) return ProxyCoverage.notClaimed;
    if (binding == ProxyBinding.processWide) return ProxyCoverage.established;
    return isMountNavigation
        ? ProxyCoverage.established
        : ProxyCoverage.unprovable;
  }
}

/// One WebView's view of [ProxyCoverageEngine], holding the single piece of
/// state the decision needs: whether the mounting navigation has gone yet.
///
/// Owned by whatever builds the WebView and asked once per navigation. A
/// remount makes a fresh gate, which is what turns "open the blocked
/// destination" into a covered navigation rather than a bypass.
class ProxyCoverageGate {
  ProxyCoverageGate({
    required this.binding,
    required this.proxyConfigured,
    required this.mountUrl,
  });

  final ProxyBinding binding;
  final bool proxyConfigured;

  /// The URL the WebView was constructed with. Matching on it rather than
  /// counting navigations is the fail-closed reading: a platform that does
  /// not report the mounting navigation through this seam at all would
  /// otherwise hand the slot to whatever the page navigated to first.
  final String mountUrl;

  bool _mountSlotSpent = false;

  /// Answer for the navigation about to be issued, spending the mount slot.
  ProxyCoverage evaluate(String url) {
    final isMountNavigation = !_mountSlotSpent && url == mountUrl;
    _mountSlotSpent = true;
    return ProxyCoverageEngine.coverageFor(
      binding: binding,
      proxyConfigured: proxyConfigured,
      isMountNavigation: isMountNavigation,
    );
  }
}
