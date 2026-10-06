/// The downloadable site search list (LIR-036): Kagi's community list of
/// bangs (github.com/kagisearch/bangs, MIT), reduced to one search address
/// per site. Pure Dart: [SiteSearchListService] downloads and stores it, this
/// file decides what a bang is worth and which site it searches.
library;

import 'package:webspace/services/web_search_engine.dart'
    show WebSearchEngine, kSearchQueryToken;
import 'package:webspace/web_view_model.dart' show getNormalizedDomain;

/// Where the list is downloaded from.
const String kSiteSearchListUrl =
    'https://raw.githubusercontent.com/kagisearch/bangs/main/data/bangs.json';

const String _bangQuery = '{{{s}}}';

String _foldWww(String host) =>
    host.startsWith('www.') ? host.substring(4) : host;

/// The search address [entry], one bang, gives its site, or null when it is
/// not a plain search of that site: a relative address (a search on Kagi), a
/// query that is not a whole parameter value (`[java]+{{{s}}}`, a page path),
/// a search restricted to another site, or an address off the bang's domain.
String? _addressOf(Map entry) {
  final url = entry['u'];
  final domain = entry['d'];
  if (url is! String || domain is! String || domain.isEmpty) return null;
  if (!url.startsWith('https://') && !url.startsWith('http://')) return null;
  final fmt = entry['fmt'];
  if (fmt is List && fmt.any((f) => f != 'url_encode_placeholder')) {
    return null;
  }
  final query = url.indexOf('?');
  if (query < 0 || url.indexOf(_bangQuery) < query) return null;
  if (_bangQuery.allMatches(url).length != 1) return null;
  if (!RegExp(r'[?&][^=&#]+=\{\{\{s\}\}\}(&|$)').hasMatch(url)) return null;
  final lower = url.toLowerCase();
  if (lower.contains('site:') ||
      lower.contains('site%3a') ||
      lower.contains('sites=')) {
    return null;
  }
  final address = url.replaceFirst(_bangQuery, kSearchQueryToken);
  if (!WebSearchEngine.isValidTemplate(address)) return null;
  if (getNormalizedDomain(address.replaceFirst(kSearchQueryToken, 'q')) !=
      getNormalizedDomain('https://$domain/')) {
    return null;
  }
  return address;
}

/// How well [entry] stands for its site: the bang named after the site
/// (`imdb` for imdb.com, `archive` for archive.org) first, since a short
/// trigger is as often a narrower search (`prel` on archive.org searches one
/// collection); then the one with fewest parameters; then the shortest
/// trigger.
(int, int, int) _rank(Map entry, String address) {
  final label = _foldWww((entry['d'] as String).toLowerCase()).split('.').first;
  final trigger = entry['t'] is String ? entry['t'] as String : '';
  final aliases = entry['ts'] is List ? entry['ts'] as List : const [];
  final named = trigger == label || aliases.contains(label) ? 0 : 1;
  final params = '&'.allMatches(address).length;
  return (named, params, trigger.length);
}

int _compare((int, int, int) a, (int, int, int) b) {
  if (a.$1 != b.$1) return a.$1 - b.$1;
  if (a.$2 != b.$2) return a.$2 - b.$2;
  return a.$3 - b.$3;
}

/// One search address per site from [bangs], the list as downloaded, keyed
/// by host without a leading `www.`. Entries of the wrong shape are skipped,
/// never fatal: the list is third-party data.
Map<String, String> siteSearchTable(Object? bangs) {
  final best = <String, (String, (int, int, int))>{};
  if (bangs is! List) return const {};
  for (final entry in bangs) {
    if (entry is! Map) continue;
    final address = _addressOf(entry);
    if (address == null) continue;
    final host = _foldWww((entry['d'] as String).toLowerCase());
    final rank = _rank(entry, address);
    final held = best[host];
    if (held == null || _compare(rank, held.$2) < 0) {
      best[host] = (address, rank);
    }
  }
  return {for (final e in best.entries) e.key: e.value.$1};
}

/// The address [table] lists for the site at [initUrl]: its host's, else
/// its domain's (`m.imdb.com` searches as `imdb.com`), and only one inside
/// the site's own domain. Null when the list names none.
String? listedAddressFor(Map<String, String> table, String initUrl) {
  if (table.isEmpty) return null;
  final host = Uri.tryParse(initUrl)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  final address =
      table[_foldWww(host)] ?? table[getNormalizedDomain(initUrl)];
  if (address == null) return null;
  return WebSearchEngine.acceptsDiscovered(address, initUrl) ? address : null;
}
