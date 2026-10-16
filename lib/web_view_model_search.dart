import 'package:webspace/services/opensearch_engine.dart' show DiscoveredSearch;
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// How a site searches, and the search sites it names (LIR-028, LIR-031).
extension WebViewModelSearch on WebViewModel {
  /// How this site searches, if it does (LIR-028).
  SearchCapability? get searchCapability => WebSearchEngine.capabilityOf(
        initUrl: initUrl,
        searchAddress: searchAddress,
        searchesWeb: searchesWeb,
        discoveredAddress: discoveredSearchAddress,
        discoveredWeb: discoveredSearchesWeb,
        listedAddress: SiteSearchListService.instance.addressFor(initUrl),
      );

  /// Take [found] as what this site's pages declared. True when it changed
  /// anything, for the caller to persist.
  bool offerDiscoveredSearch(DiscoveredSearch found) {
    if (discoveredSearchAddress == found.address &&
        discoveredSearchesWeb == found.web) {
      return false;
    }
    discoveredSearchAddress = found.address;
    discoveredSearchesWeb = found.web;
    return true;
  }

  /// Drop the [searchSites] and [searchDefault] entries that name no
  /// candidate (LIR-031). True when anything was dropped.
  bool pruneSearchReferences(bool Function(SiteId siteId) isCandidate) {
    final kept = [
      for (final id in searchSites)
        if (isCandidate(id)) id,
    ];
    final def = searchDefault;
    final dropDefault = def != null && !isCandidate(def);
    if (kept.length == searchSites.length && !dropDefault) return false;
    searchSites = kept;
    if (dropDefault) searchDefault = null;
    return true;
  }
}
