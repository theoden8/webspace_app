import 'package:webspace/settings/proxy.dart';

/// Pure-Dart engine for the Android process-wide proxy constraint
/// (NOTIF-005-A). `androidx.webkit.ProxyController.setProxyOverride`
/// applies to ALL WebViews regardless of profile, so two background-poll
/// sites with different proxies cannot run concurrently — only the
/// most-recently-applied proxy is in effect.
///
/// The engine exposes two pure functions:
///
///   - [fingerprint] — collapses a [UserProxySettings] into a single
///     string. Sites with identical fingerprints can run as
///     background-poll concurrently; differing fingerprints conflict.
///
///   - [canEnable] — answers "can this site become a background-poll
///     site without violating the constraint?" given the proxies of the
///     OTHER currently-enabled sites.
///
/// Stays free of Flutter widgets / platform channels so it's testable in
/// pure Dart and so [CookieIsolationEngine]-style behavior can be unit-
/// covered without spinning up the Android channel.
class ProxyConflictEngine {
  /// Collapse a [UserProxySettings] into the fingerprint that
  /// `ProxyController.setProxyOverride` actually distinguishes on. All
  /// `DEFAULT` proxies are equivalent (no override applied); custom
  /// proxies hash their full tuple including credentials, since
  /// [ProxyController] differentiates them.
  static String fingerprint(UserProxySettings p) {
    if (p.type == ProxyType.DEFAULT) return 'default';
    final type = p.type.toString().split('.').last;
    final addr = p.address ?? '';
    final user = p.username ?? '';
    final pwd = p.password ?? '';
    return '$type|$addr|$user|$pwd';
  }

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
  static bool canEnable({
    required UserProxySettings targetProxy,
    required Iterable<UserProxySettings> otherEnabledProxies,
  }) {
    final targetFp = fingerprint(targetProxy);
    for (final other in otherEnabledProxies) {
      if (fingerprint(other) != targetFp) return false;
    }
    return true;
  }

  /// First conflicting fingerprint, for human-readable explanatory
  /// subtitles ("Cannot enable: another site is already polling with a
  /// different proxy"). Returns null when [canEnable] would return true.
  static UserProxySettings? firstConflict({
    required UserProxySettings targetProxy,
    required Iterable<UserProxySettings> otherEnabledProxies,
  }) {
    final targetFp = fingerprint(targetProxy);
    for (final other in otherEnabledProxies) {
      if (fingerprint(other) != targetFp) return other;
    }
    return null;
  }
}
