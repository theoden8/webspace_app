/// HTTPS upgrade decisions for main-frame navigations (HTTPS-001..005), and
/// the move of a site's clearnet origin onto the onion origin it announced
/// (ONION-004, ONION-006): both rewrite a top-frame URL to a better transport
/// and fall back silently to the one asked for, through the same events.
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
/// load failure back through [fallbackFor] so the next attempt on that host
/// does not pay the same timeout.
library;

import 'package:webspace/services/onion_location.dart';
import 'package:webspace/services/url_host.dart';

/// What the call site must do about an event. Every field is an instruction to
/// a native API, never a decision: `load` is a URL to hand `loadUrl`, `cancel`
/// answers `shouldOverrideUrlLoading` / the trust challenge, and
/// `armDeadlineFor` is the upgraded URL a timer must be set for.
///
/// The point of returning this rather than acting is that the whole state
/// machine then runs in a plain Dart test, event by event, in any order the
/// platform might deliver them. A call site that branches on engine state
/// instead of forwarding is a decision no test can reach.
typedef UpgradeOutcome = ({String? load, bool cancel, String? armDeadlineFor});

const UpgradeOutcome _nothing = (load: null, cancel: false, armDeadlineFor: null);

/// Decides whether a main-frame navigation should be retried over https, and
/// what to do when that retry fails.
///
/// One instance per app process. The http-only host set is deliberately in
/// memory and never persisted (HTTPS-002): on disk it would be per-host state
/// that varies with which sites exist, which ARCH-001 would have to reason
/// about, and a wrong entry would outlive its cause with nothing in the UI to
/// show or clear it.
class HttpsUpgradeEngine {
  HttpsUpgradeEngine({
    this.deadline = const Duration(seconds: 8),
    this.onionDeadline = const Duration(seconds: 30),
  });

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

  /// How long a move onto an onion origin may go without a verdict
  /// (ONION-006): a new circuit to an onion service takes several seconds
  /// before the server has said anything.
  final Duration onionDeadline;

  /// Hosts that answered an upgrade attempt with a failure.
  final Set<Host> _httpOnlyHosts = <Host>{};

  /// Onion services a move onto failed this run (ONION-006), in memory only
  /// for the reason [_httpOnlyHosts] is.
  final Set<OnionAddress> _failedOnions = <OnionAddress>{};

  /// The in-flight entries of [_inFlight] that are moves onto an onion
  /// origin, each with the service it went to.
  final Map<String, OnionAddress> _onionInFlight = <String, OnionAddress>{};

  /// Upgraded URL currently in flight -> the http URL it came from. An entry
  /// lives from the moment the call site issues the upgrade until that
  /// navigation succeeds or fails. Insertion-ordered, which [fallbackForHost]
  /// relies on.
  final Map<String, String> _inFlight = <String, String>{};

  /// In-flight upgrades whose server has answered. The deadline is about a
  /// connection that never got going, not a page that is slow to finish, and
  /// the difference is not one a timer can see on its own.
  final Set<String> _responded = <String>{};

  /// The https URL to load instead of [url], or null to leave the navigation
  /// alone. [enabled] is the site's effective setting, so a disabled site
  /// short-circuits before any parsing.
  ///
  /// Call this AFTER the navigation decision has allowed [url] (HTTPS-004).
  /// Taken first, a scheme rewrite is a way back into the navigation pipeline
  /// with the gesture requirement and cross-domain nested routing already
  /// behind it — the hole CAPTCHA-008 had to close for the
  /// captcha allow.
  String? upgradeFor(String url, {required bool enabled}) {
    if (!enabled) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'http') return null;
    final host = uri.host;
    if (host.isEmpty) return null;
    if (_httpOnlyHosts.contains(Host(host))) return null;
    if (!_canBeExpectedToServeTls(host)) return null;
    // An explicit :80 is the default it would have had anyway, so drop it and
    // upgrade. Any other port is an ad-hoc service that https would not answer.
    if (uri.hasPort && uri.port != 80) return null;

    final upgraded = uri.replace(scheme: 'https', port: null).toString();
    _inFlight[upgraded] = url;
    return upgraded;
  }

  /// [url] on the onion origin [endpoint] names, or null to leave it: no
  /// endpoint (the site is not on Tor or has none accepted, ONION-007), a URL
  /// off the announcing origin, or a service that failed this run
  /// (ONION-006). Called where [upgradeFor] is, and before it (ONION-004).
  String? onionFor(String url, {required OnionEndpoint? endpoint}) {
    if (endpoint == null || _failedOnions.contains(endpoint.service)) {
      return null;
    }
    final moved = endpoint.rewrite(url);
    if (moved == null) return null;
    _inFlight[moved] = url;
    _onionInFlight[moved] = endpoint.service;
    return moved;
  }

  /// How long the call site waits on [upgradedUrl] before [onDeadline].
  Duration deadlineFor(String upgradedUrl) =>
      _onionInFlight.containsKey(upgradedUrl) ? onionDeadline : deadline;

  /// Records that the rewrite to [upgradedUrl] failed, against what it
  /// rewrote to: an onion service, or a host that will not serve https.
  void _failed(String upgradedUrl) {
    final onion = _onionInFlight.remove(upgradedUrl);
    if (onion != null) {
      _failedOnions.add(onion);
      return;
    }
    final host = Host.inUrl(upgradedUrl);
    if (host != null) _httpOnlyHosts.add(host);
  }

  /// The http URL to fall back to after [failedUrl] failed to load, or null
  /// when this engine did not upgrade it.
  ///
  /// Only the engine's own upgrades are reversed. Downgrading a URL the site
  /// asked for over https would be an attack dressed as a recovery, so a
  /// failure on an https URL nobody upgraded returns null and the failure
  /// stays the user's to see.
  String? fallbackFor(String failedUrl) {
    _responded.remove(failedUrl);
    final original = _inFlight.remove(failedUrl);
    if (original == null) return null;
    _failed(failedUrl);
    return original;
  }

  /// Note that the server has answered for [upgradedUrl], so the deadline no
  /// longer applies to it.
  ///
  /// Without this the deadline cannot tell a connection that never got going
  /// from a page that is merely slow, and an https host on a bad link gets
  /// downgraded for being slow — and recorded http-only for the rest of the
  /// session, which is the feature doing the exact opposite of its job.
  void noteUpgradeResponded(String upgradedUrl) {
    if (_inFlight.containsKey(upgradedUrl)) _responded.add(upgradedUrl);
  }

  /// The fallback for an upgrade whose deadline passed with no verdict.
  ///
  /// Two ways this returns null, and both matter. A deadline that fires after
  /// the load already succeeded finds no in-flight entry, because
  /// [recordUpgradeSuccess] removed it. A deadline that fires while the server
  /// is answering finds one, but the connection is alive and abandoning it
  /// would downgrade a working host for being slow.
  String? fallbackForTimeout(String upgradedUrl) {
    if (_responded.contains(upgradedUrl)) return null;
    return fallbackFor(upgradedUrl);
  }

  /// The http URL to fall back to for an in-flight upgrade to [host], or null
  /// when this engine has no upgrade in flight there.
  ///
  /// Keyed by host rather than URL because the platform's certificate callback
  /// identifies a protection space, not a navigation: it knows the host and
  /// port that failed, never the URL that asked. Same bookkeeping as
  /// [fallbackFor] otherwise.
  String? fallbackForHost(String host) {
    final wanted = Host(host);
    final matching = _inFlight.keys
        .where((k) => Host.inUrl(k) == wanted)
        .toList(growable: false);
    if (matching.isEmpty) return null;
    // Every upgrade to this host is doomed by the same certificate, so clear
    // them all rather than leaving siblings in flight for a later callback to
    // reverse. The URL handed back is the most recent, which is the one the
    // user is waiting on: the root webview and its nested webviews share one
    // engine (HTTPS-002), so two upgrades to a host can be in flight at once,
    // and taking whichever the map happened to hold first could send the user
    // to a page they had already left.
    final original = _inFlight[matching.last]!;
    for (final k in matching) {
      _failed(k);
      _inFlight.remove(k);
      _responded.remove(k);
    }
    return original;
  }

  /// Note that [upgradedUrl] loaded successfully, dropping its in-flight entry.
  /// Without this the map grows by one per upgraded navigation for the life of
  /// the process, and a later unrelated failure on the same URL string would
  /// read as a fallback long after the fact.
  void recordUpgradeSuccess(String upgradedUrl) {
    _inFlight.remove(upgradedUrl);
    _onionInFlight.remove(upgradedUrl);
    _responded.remove(upgradedUrl);
  }

  /// Whether [host] has been recorded http-only this process.
  bool isKnownHttpOnly(String host) => _httpOnlyHosts.contains(Host(host));

  /// Test seam: forget every recorded host and in-flight upgrade.
  void reset() {
    _httpOnlyHosts.clear();
    _failedOnions.clear();
    _onionInFlight.clear();
    _inFlight.clear();
    _responded.clear();
  }

  // The four platform events that can resolve an upgrade, plus the deadline.
  // The call site forwards each one and obeys the outcome; it holds no state
  // and makes no choice of its own, so every ordering below is reachable from
  // a unit test rather than only from a device.

  /// A main-frame navigation the routing decision has already allowed
  /// (HTTPS-004).
  ///
  /// [onion] is the site's accepted onion endpoint while it is on Tor, else
  /// null. A move onto it comes first, so a plain-http clearnet URL goes to
  /// the onion rather than through an https upgrade (ONION-004).
  UpgradeOutcome onNavigation(
    String url, {
    required bool enabled,
    required OnionEndpoint? onion,
  }) {
    final upgraded =
        onionFor(url, endpoint: onion) ?? upgradeFor(url, enabled: enabled);
    if (upgraded == null) return _nothing;
    return (load: upgraded, cancel: true, armDeadlineFor: upgraded);
  }

  /// A webview's first load, which reaches no navigation callback on
  /// Android: only the move onto the site's onion origin applies to it
  /// (ONION-004), [onion] as [onNavigation] takes it. The call site loads
  /// [UpgradeOutcome.load] in its place and arms the deadline.
  UpgradeOutcome onFirstLoad(String url, {required OnionEndpoint? onion}) {
    final moved = onionFor(url, endpoint: onion);
    if (moved == null) return _nothing;
    return (load: moved, cancel: false, armDeadlineFor: moved);
  }

  /// The main frame began loading [url]: for an upgrade of ours that is the
  /// server answering, which takes it out of the deadline's reach.
  UpgradeOutcome onLoadStarted(String url) {
    noteUpgradeResponded(url);
    return _nothing;
  }

  UpgradeOutcome onLoadFinished(String url) {
    recordUpgradeSuccess(url);
    return _nothing;
  }

  /// [url] failed to load. Sub-frame failures are not ours: the engine only
  /// ever upgrades the main frame (HTTPS-004).
  UpgradeOutcome onLoadFailed(String url, {required bool isMainFrame}) {
    if (!isMainFrame) return _nothing;
    final fallback = fallbackFor(url);
    if (fallback == null) return _nothing;
    return (load: fallback, cancel: false, armDeadlineFor: null);
  }

  /// The platform rejected [host]'s certificate (HTTPS-007). Cancels the
  /// challenge so no prompt is shown and nothing is pinned.
  UpgradeOutcome onCertificateRejected(String host) {
    final fallback = fallbackForHost(host);
    if (fallback == null) return _nothing;
    return (load: fallback, cancel: true, armDeadlineFor: null);
  }

  /// The deadline armed for [upgradedUrl] fired.
  ///
  /// [generationAtArm] and [currentGeneration] are the repo's race-protection
  /// signature: the engine bails on a navigation the user has since left
  /// without knowing what a navigation generation is, and the check is a unit
  /// test rather than a line of call-site code no test can see.
  UpgradeOutcome onDeadline(
    String upgradedUrl, {
    required int generationAtArm,
    required int Function() currentGeneration,
  }) {
    if (currentGeneration() != generationAtArm) return _nothing;
    final fallback = fallbackForTimeout(upgradedUrl);
    if (fallback == null) return _nothing;
    return (load: fallback, cancel: false, armDeadlineFor: null);
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
    // An overlay network already encrypts its sites' traffic end to end and
    // checks their key, which is their address; many serve plain http only.
    if (Host(lower).overlay != null) return false;
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
