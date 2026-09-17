/// HTTPS upgrade decisions for main-frame navigations (HTTPS-001..005).
///
/// Chromium has upgraded ordinary navigations since Chrome 115 and falls back
/// silently when https does not answer. Android WebView does not carry that
/// behaviour, so a plain-http URL that enters the app from a typed host, an old
/// site entry, a link or a server redirect stays plaintext for as long as the
/// origin tolerates it — and an origin that answers 200 on both schemes with no
/// redirect and no HSTS tolerates it forever.
///
/// Pure: no Flutter, no platform channel, no network. The engine decides; the
/// call site cancels the navigation and loads what it returns, and reports a
/// load failure back through [recordUpgradeFailure] so the next attempt on that
/// host does not pay the same timeout.
library;

/// Decides whether a main-frame navigation should be retried over https, and
/// what to do when that retry fails.
///
/// One instance per app process. The http-only host set is deliberately in
/// memory and never persisted (HTTPS-002): on disk it would be per-host state
/// that varies with which sites exist, which ARCH-001 would have to reason
/// about, and a wrong entry would outlive its cause with nothing in the UI to
/// show or clear it.
class HttpsUpgradeEngine {
  HttpsUpgradeEngine({this.deadline = const Duration(seconds: 8)});

  /// How long an upgraded navigation may go without a verdict before the call
  /// site treats it as failed (HTTPS-002).
  ///
  /// A refused port errors immediately, but a port that accepts and then says
  /// nothing — a firewall blackholing 443, which is the shape of a captive
  /// portal — produces no error at all for as long as the engine's own
  /// timeouts allow. Without a deadline the page just sits there, on a site
  /// that would have loaded instantly over http, and the fallback this
  /// requirement promises never runs.
  ///
  /// Eight seconds: long enough that a slow-but-live TLS host is not cut off
  /// (a handshake over a bad mobile link is well under this), short enough
  /// that a blackhole costs a pause rather than a hang.
  final Duration deadline;

  /// Hosts that answered an upgrade attempt with a failure, lowercased.
  final Set<String> _httpOnlyHosts = <String>{};

  /// Upgraded URL currently in flight -> the http URL it came from. An entry
  /// lives from the moment the call site issues the upgrade until that
  /// navigation succeeds or fails.
  final Map<String, String> _inFlight = <String, String>{};

  /// The https URL to load instead of [url], or null to leave the navigation
  /// alone. [enabled] is the site's effective setting, so a disabled site
  /// short-circuits before any parsing.
  ///
  /// Call this AFTER the navigation decision has allowed [url] (HTTPS-004).
  /// Taken first, a scheme rewrite is a way back into the navigation pipeline
  /// with `blockAutoRedirects`, the gesture requirement and cross-domain nested
  /// routing already behind it — the hole CAPTCHA-008 had to close for the
  /// captcha allow.
  String? upgradeFor(String url, {required bool enabled}) {
    if (!enabled) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'http') return null;
    final host = uri.host;
    if (host.isEmpty) return null;
    if (_httpOnlyHosts.contains(host.toLowerCase())) return null;
    if (!_canBeExpectedToServeTls(host)) return null;
    // An explicit :80 is the default it would have had anyway, so drop it and
    // upgrade. Any other port is an ad-hoc service that https would not answer.
    if (uri.hasPort && uri.port != 80) return null;

    final upgraded = uri.replace(scheme: 'https', port: null).toString();
    _inFlight[upgraded] = url;
    return upgraded;
  }

  /// The http URL to fall back to after [failedUrl] failed to load, or null
  /// when this engine did not upgrade it.
  ///
  /// Only the engine's own upgrades are reversed. Downgrading a URL the site
  /// asked for over https would be an attack dressed as a recovery, so a
  /// failure on an https URL nobody upgraded returns null and the failure
  /// stays the user's to see.
  String? fallbackFor(String failedUrl) {
    final original = _inFlight.remove(failedUrl);
    if (original == null) return null;
    final host = Uri.tryParse(failedUrl)?.host;
    if (host != null && host.isNotEmpty) _httpOnlyHosts.add(host.toLowerCase());
    return original;
  }

  /// The fallback for an upgrade whose deadline passed with no verdict.
  ///
  /// Deliberately the same call as [fallbackFor] rather than a path of its
  /// own: a deadline that fires after the load already succeeded MUST be a
  /// no-op, and the in-flight entry [recordUpgradeSuccess] removes is what
  /// makes it one. A separate path that re-derived the http URL would happily
  /// downgrade a page that is already up over https.
  String? fallbackForTimeout(String upgradedUrl) => fallbackFor(upgradedUrl);

  /// Note that [upgradedUrl] loaded successfully, dropping its in-flight entry.
  /// Without this the map grows by one per upgraded navigation for the life of
  /// the process, and a later unrelated failure on the same URL string would
  /// read as a fallback long after the fact.
  void recordUpgradeSuccess(String upgradedUrl) {
    _inFlight.remove(upgradedUrl);
  }

  /// Mark [host] http-only without having an in-flight upgrade to reverse.
  /// For a call site that learns the host has no TLS by another route.
  void recordUpgradeFailure(String host) {
    if (host.isNotEmpty) _httpOnlyHosts.add(host.toLowerCase());
  }

  /// Whether [host] has been recorded http-only this process.
  bool isKnownHttpOnly(String host) =>
      _httpOnlyHosts.contains(host.toLowerCase());

  /// Test seam: forget every recorded host and in-flight upgrade.
  void reset() {
    _httpOnlyHosts.clear();
    _inFlight.clear();
  }

  /// Whether a certificate could plausibly validate for [host] (HTTPS-003).
  ///
  /// LAN devices, developer servers and `.local` names routinely have no
  /// certificate that would validate, so upgrading them buys a guaranteed
  /// failed connection and a fallback on every launch — and behind a captive
  /// portal, a visible stall.
  static bool _canBeExpectedToServeTls(String host) {
    if (_isIpLiteral(host)) return false;
    final lower = host.toLowerCase();
    if (lower.endsWith('.local')) return false;
    // Single-label names ("localhost", "nas", "router") are not public DNS
    // names and cannot carry a publicly-trusted certificate.
    if (!lower.contains('.')) return false;
    return true;
  }

  static bool _isIpLiteral(String host) {
    // Uri.host keeps IPv6 literals bracketless, so a colon is enough.
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }
}
