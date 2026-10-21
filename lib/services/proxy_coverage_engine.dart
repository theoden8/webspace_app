import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/url_host.dart';

/// Whether a navigation a site is about to issue can be shown to go through
/// the route it needs (LEAK-010, LEAK-016).
sealed class ProxyCoverage {
  const ProxyCoverage();
}

/// The site runs on DEFAULT with no global proxy behind it and the
/// destination needs none, so no claim about a proxy is being made and
/// nothing has to be established.
final class NotClaimed extends ProxyCoverage {
  const NotClaimed();
}

/// The request is bound to the proxy the user configured.
final class Established extends ProxyCoverage {
  const Established();
}

/// The navigation is cancelled before any byte leaves the device. Which case
/// it is decides what the interstitial tells the user.
sealed class Uncovered extends ProxyCoverage {
  const Uncovered();

  /// What the `Proxy` log entry says was missing.
  String get logLabel => switch (this) {
        Unprovable() => 'proxy coverage not established',
        OnionNeedsProxy() => 'an onion service on a site with no proxy',
      };
}

/// The app cannot establish that the request would be proxied. This is not
/// "the proxy is down" and not "the request failed": nothing was sent.
final class Unprovable extends Uncovered {
  const Unprovable();
}

/// The destination is an onion service and the site has no proxy: neither
/// Tor, built in or external, nor one of the user's. Only Tor resolves the
/// name, so going direct would only hand it to the device's resolver.
final class OnionNeedsProxy extends Uncovered {
  const OnionNeedsProxy();
}

/// A navigation the gate cancelled, as its interstitial names it.
typedef BlockedNavigation = ({String url, Uncovered why});

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
  /// [Unprovable], on a measurement that could not have
  /// read anything else (BUG-014 caution 2). **Those readings are void.** Every proxy arm behind them pointed its
  /// origins at an address of the test machine itself, which macOS routes
  /// over `lo0` and never proxies, so they read DIRECT whether or not the
  /// proxy was bound. The remeasurement against a destination the
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
  ///
  /// [destination] is the host the navigation names, or null for none. Any
  /// proxy the user chose may carry an onion service: Tor resolves it, and a
  /// proxy is handed the name rather than an address, so only a site with no
  /// proxy at all is refused one.
  static ProxyCoverage coverageFor({
    required ProxyBinding binding,
    required bool proxyConfigured,
    required Host? destination,
    required bool isMountNavigation,
  }) {
    if (proxyConfigured) return const Established();
    if (destination != null && destination.isOnion) {
      return const OnionNeedsProxy();
    }
    return const NotClaimed();
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

  /// Answer for a frame the page embeds, which is never the mount.
  ProxyCoverage evaluateFrame(String url) => ProxyCoverageEngine.coverageFor(
        binding: binding,
        proxyConfigured: proxyConfigured,
        destination: Host.inUrl(url),
        isMountNavigation: false,
      );

  /// Answer for the navigation about to be issued, spending the mount slot.
  ProxyCoverage evaluate(String url) {
    final isMountNavigation = !_mountSlotSpent && url == mountUrl;
    _mountSlotSpent = true;
    return ProxyCoverageEngine.coverageFor(
      binding: binding,
      proxyConfigured: proxyConfigured,
      destination: Host.inUrl(url),
      isMountNavigation: isMountNavigation,
    );
  }
}
