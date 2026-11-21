import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/web_view_model.dart';

/// What a headless check depends on that is the same for every site in a
/// wake.
class WakeEnvironment {
  /// Native containers are in use. Under legacy isolation sites share one
  /// cookie jar, which a headless check would read as whichever site last
  /// held it.
  final bool containers;

  final bool torUp;

  const WakeEnvironment({required this.containers, required this.torUp});
}

/// Whether a wake gives Tor time to come up before it plans (TOR-006): a
/// notification site it would check routes through Tor, and Tor is not up.
/// A process the OS started for the wake has Tor still bootstrapping, and a
/// plan made then would skip every such site as [WakeSkip.torDown].
bool wakeWaitsForTor(Iterable<WebViewModel> sites, {required bool torUp}) =>
    sites.any((m) =>
        m.effectiveNotificationsEnabled &&
        waitsForTor(m.outboundProxy, torUp: torUp));

/// [m] as a background wake sees it. [loaded] and [hasWebview] are the slot's
/// state; [proxyBindable] is false when the site's proxy cannot be bound to a
/// webview (SEC-009).
WakeCandidate wakeCandidateFor(
  WebViewModel m, {
  required bool loaded,
  required bool hasWebview,
  required bool proxyBindable,
  required WakeEnvironment env,
}) {
  WakeSkip? blocked;
  if (!env.containers) {
    blocked = WakeSkip.legacyIsolation;
  } else if (!m.initUrl.startsWith('http')) {
    blocked = WakeSkip.localPage;
  } else if (m.effectiveIncognito) {
    blocked = WakeSkip.incognito;
  } else if (waitsForTor(m.outboundProxy, torUp: env.torUp)) {
    blocked = WakeSkip.torDown;
  } else if (!proxyBindable) {
    blocked = WakeSkip.proxyUnavailable;
  }
  return WakeCandidate(
    site: WakeSite(siteId: m.siteId, name: m.name),
    notificationsEnabled: m.effectiveNotificationsEnabled,
    live: loaded && hasWebview,
    headlessBlocked: blocked,
  );
}
