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
  /// the WebView. It no longer changes the answer, and is kept so a platform
  /// that turns out to need the distinction has somewhere to put it.
  ///
  /// It used to: under [ProxyBinding.perSite] every post-mount navigation was
  /// [ProxyCoverage.unprovable], on the strength of BUG-014 attempts 90 and
  /// 92. **Those readings are void.** Every proxy arm behind them pointed its
  /// origins at an address of the test machine itself, which macOS routes
  /// over `lo0` and never proxies, so they read DIRECT whether or not the
  /// proxy was bound. Attempt 102 remeasured against a destination the
  /// machine does not own: a store's proxy covers every navigation on it, at
  /// any distance from the first frame, on `nonPersistent()` and
  /// `forIdentifier:` alike, and on a second navigation to a different
  /// origin. So a per-site binding establishes coverage exactly as a
  /// process-wide one does, and cancelling post-mount navigations was
  /// blocking traffic the proxy was already carrying.
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
    return ProxyCoverage.established;
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
