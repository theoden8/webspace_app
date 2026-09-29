import 'package:webspace/services/tor_engine.dart' show kTorAppGlobalTag;

/// Holder reason for a nested browser opened from a site: the site's id
/// follows the prefix.
const String kTorNestedHolderPrefix = 'nested:';

/// Holder reason for the interstitial in front of a Tor-bound page. It holds
/// on behalf of a site or the app-wide proxy, which hold on their own.
const String kTorInterstitialHolderPrefix = 'interstitial:';

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
  Iterable<String> holders,
  Map<String, String> siteNames,
) {
  var appWide = false;
  final siteIds = <String>{};
  for (final holder in holders) {
    if (holder == kTorAppGlobalTag) {
      appWide = true;
    } else if (holder.startsWith(kTorNestedHolderPrefix)) {
      siteIds.add(holder.substring(kTorNestedHolderPrefix.length));
    } else if (!holder.startsWith(kTorInterstitialHolderPrefix)) {
      siteIds.add(holder);
    }
  }
  final names = <String>[
    for (final id in siteIds) ?siteNames[id],
  ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return TorHolderSummary(
    appWide: appWide,
    sites: names,
    otherSites: siteIds.length - names.length,
  );
}
