import 'package:webspace/services/outbound_http_types.dart'
    show OutboundProxy, resolveEffectiveProxy;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

/// Pure-Dart engine for the Android process-wide proxy constraint
/// (NOTIF-005-A). `androidx.webkit.ProxyController.setProxyOverride`
/// applies to ALL WebViews regardless of profile, so two background-poll
/// sites with different proxies cannot run concurrently — only the
/// most-recently-applied proxy is in effect.
///
/// The engine exposes two pure functions:
///
///   - [fingerprint] — the route a site's traffic takes. Sites with equal
///     fingerprints can run as background-poll concurrently; differing
///     fingerprints conflict.
///
///   - [canEnable] — answers "can this site become a background-poll
///     site without violating the constraint?" given the proxies of the
///     OTHER currently-enabled sites.
///
/// Stays free of Flutter widgets / platform channels so it's testable in
/// pure Dart and so [CookieIsolationEngine]-style behavior can be unit-
/// covered without spinning up the Android channel.
class ProxyConflictEngine {
  /// The route `ProxyController.setProxyOverride` would apply for a site
  /// set to [p]: its effective proxy, the same one PROXY-008 compares, so
  /// a DEFAULT site and one set to the proxy it inherits agree, and two
  /// sites naming different saved proxies do not.
  static ProxyRouteKey fingerprint(OutboundProxy p) => p.resolved.routeKey;

  /// The route [siteId]'s traffic takes when set to [p], its Tor tag
  /// included (PROXY-011): what the process-wide rule is set to for it and
  /// what two of its occupants compare (PROXY-008).
  static ProxyRouteKey routeOf(UserProxySettings p, {required SiteId siteId}) =>
      resolveEffectiveProxy(p, siteId: siteId).routeKey;

  /// True iff the candidate site can be flipped to background-poll
  /// without breaking the process-wide proxy constraint.
  ///
  /// Equivalent to: every entry in [otherEnabledProxies] has the same
  /// fingerprint as [targetProxy]. The set of enabled fingerprints
  /// post-toggle would have cardinality 1.
  ///
  /// [otherEnabledProxies] MUST exclude the target site's own proxy —
  /// the caller owns the filter on `notificationsEnabled` AND `index !=
  /// targetIndex`.
  ///
  /// [routesPerSite] lifts the constraint entirely: under router mode
  /// (PROXY-013) the process-wide rule points at the loopback router for
  /// good and each site reaches its own upstream through its own
  /// credential, so two background-poll sites with different proxies no
  /// longer contend for a single slot.
  static bool canEnable({
    required OutboundProxy targetProxy,
    required Iterable<OutboundProxy> otherEnabledProxies,
    bool routesPerSite = false,
  }) =>
      firstConflict(
        targetProxy: targetProxy,
        others: otherEnabledProxies,
        proxyOf: (p) => p,
        routesPerSite: routesPerSite,
      ) ==
      null;

  /// The first of [others] whose route differs from [targetProxy], for the
  /// explanation that names who blocks the toggle ("Cannot enable: Site A
  /// polls with a different proxy"). Null when [canEnable] would be true.
  static T? firstConflict<T>({
    required OutboundProxy targetProxy,
    required Iterable<T> others,
    required OutboundProxy Function(T other) proxyOf,
    bool routesPerSite = false,
  }) {
    if (routesPerSite) return null;
    final target = fingerprint(targetProxy);
    for (final other in others) {
      if (fingerprint(proxyOf(other)) != target) return other;
    }
    return null;
  }
}
