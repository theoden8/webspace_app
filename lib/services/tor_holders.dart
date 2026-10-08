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

  final String siteId;

  @override
  Object? get _id => siteId;
}

/// A nested browser opened from [siteId], holding for as long as it is open.
final class TorNestedHolder extends TorHolder {
  const TorNestedHolder(this.siteId);

  final String siteId;

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

/// What is keeping the Tor runtime up, in terms a person can read.
class TorHolderSummary {
  const TorHolderSummary({
    required this.appWide,
    required this.sites,
    required this.otherSites,
  });

  /// The app-wide outbound proxy is set to Tor.
  final bool appWide;

  /// Display names of the sites routed through Tor, sorted.
  final List<String> sites;

  /// Sites routed through Tor that have no name to show, such as a site in
  /// an open archive.
  final int otherSites;

  bool get isEmpty => !appWide && sites.isEmpty && otherSites == 0;
}

/// Reads the engine's holder set against [siteNames] (siteId to name).
TorHolderSummary summarizeTorHolders(
  Iterable<TorHolder> holders,
  Map<String, String> siteNames,
) {
  var appWide = false;
  final siteIds = <String>{};
  for (final holder in holders) {
    switch (holder) {
      case TorAppWideHolder():
        appWide = true;
      case TorSiteHolder(:final siteId) || TorNestedHolder(:final siteId):
        siteIds.add(siteId);
      case TorInterstitialHolder():
        break;
    }
  }
  final names = <String>[for (final id in siteIds) ?siteNames[id]]
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return TorHolderSummary(
    appWide: appWide,
    sites: names,
    otherSites: siteIds.length - names.length,
  );
}
