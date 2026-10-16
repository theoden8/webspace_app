import 'package:webspace/settings/site_ids.dart';

/// Something keeping the Tor runtime up.
sealed class TorHolder {
  const TorHolder();

  Object? get _id;

  @override
  bool operator ==(Object other) =>
      other is TorHolder &&
      other.runtimeType == runtimeType &&
      other._id == _id;

  @override
  int get hashCode => Object.hash(runtimeType, _id);
}

/// The app-wide outbound proxy is set to Tor.
final class TorAppWideHolder extends TorHolder {
  const TorAppWideHolder();

  @override
  Object? get _id => null;
}

/// A site routed through Tor.
final class TorSiteHolder extends TorHolder {
  const TorSiteHolder(this.siteId);

  final SiteId siteId;

  @override
  Object? get _id => siteId;
}

/// A nested browser opened from [siteId], holding for as long as it is open.
final class TorNestedHolder extends TorHolder {
  const TorNestedHolder(this.siteId);

  final SiteId siteId;

  @override
  Object? get _id => siteId;
}

/// The interstitial in front of a Tor-bound page, held by the [owner]
/// showing it. It holds on behalf of a site or the app-wide proxy, which
/// hold on their own.
final class TorInterstitialHolder extends TorHolder {
  const TorInterstitialHolder(this.owner);

  final Object owner;

  @override
  Object? get _id => owner;
}

/// A connection test of a Tor route, held by the [owner] running it for as
/// long as the test runs: the route may be one the user has not saved yet,
/// which nothing else holds (PROXY-019).
final class TorTestHolder extends TorHolder {
  const TorTestHolder(this.owner);

  final Object owner;

  @override
  Object? get _id => owner;
}

/// A site as the Tor screen lists it: its name, and the country it pins
/// in tor's `ExitNodes` syntax (`{de}`), null for any (TOR-014).
typedef TorSiteLabel = ({String name, String? exitNodes});

/// What is keeping the Tor runtime up, in terms a person can read.
class TorHolderSummary {
  const TorHolderSummary({
    required this.appWide,
    required this.sites,
    required this.otherSites,
  });

  /// The app-wide outbound proxy is set to Tor.
  final bool appWide;

  /// The sites routed through Tor that have a name to show, sorted by it.
  final List<TorSiteLabel> sites;

  /// Sites routed through Tor that have no name to show, such as a site in
  /// an open archive.
  final int otherSites;

  bool get isEmpty => !appWide && sites.isEmpty && otherSites == 0;
}

/// Reads the engine's holder set against [sites]; a holder missing from it
/// is counted, never named.
TorHolderSummary summarizeTorHolders(
  Iterable<TorHolder> holders, {
  required Map<SiteId, TorSiteLabel> sites,
}) {
  var appWide = false;
  final siteIds = <SiteId>{};
  for (final holder in holders) {
    switch (holder) {
      case TorAppWideHolder():
        appWide = true;
      case TorSiteHolder(:final siteId) || TorNestedHolder(:final siteId):
        siteIds.add(siteId);
      case TorInterstitialHolder() || TorTestHolder():
        break;
    }
  }
  final named = <TorSiteLabel>[for (final id in siteIds) ?sites[id]]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return TorHolderSummary(
    appWide: appWide,
    sites: named,
    otherSites: siteIds.length - named.length,
  );
}
