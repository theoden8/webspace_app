/// The popular sites list (SUGGEST-007): the Chrome UX Report's top origins
/// by real page loads (github.com/zakird/crux-top-lists, data CC BY 4.0),
/// ranked best first, that complete an address typed on the add-site screen.
/// Pure Dart: [TopSitesService] downloads and stores the list, this file
/// decides which rows count and what a typed address matches.
library;

import 'package:webspace/services/domain_list.dart';

const String kTopSitesUrl = 'https://raw.githubusercontent.com/zakird/'
    'crux-top-lists/main/data/global/current.csv.gz';

/// The worst rank group kept: CrUX ranks origins in groups (1000, 5000,
/// 10000, 50000, ...), so this keeps about ten thousand.
const int kTopSitesRank = 10000;

/// How many matches a typed address is offered.
const int kTopSitesShown = 6;

/// The shortest typed host offered matches: a single letter matches the
/// subdomains of the largest sites more than any site the user means.
const int kTopSitesMinTyped = 2;

/// An address offered ahead of the ranked sites (SUGGEST-010) when what is
/// typed begins it or one of its [words].
typedef PinnedSite = ({String address, List<String> words});

const List<PinnedSite> kTopSitesPinned = [
  (address: 'justice.gov/epstein', words: ['epstein']),
];

/// Top-level domains the list filters (SUGGEST-009), in their DNS form, as
/// CrUX writes an origin: `.cn`, `.ru`, `.by`, `.kp`, `.рф`, `.бел`, `.中国`,
/// `.中國`, and the adult ones.
const Set<String> kTopSitesFilteredTlds = {
  'cn',
  'ru',
  'by',
  'kp',
  'xn--p1ai',
  'xn--90ais',
  'xn--fiqs8s',
  'xn--fiqz9s',
  'xxx',
  'sex',
  'porn',
  'adult',
  'sexy',
};

/// Where a filter list comes from (SUGGEST-009).
sealed class FilterSource {
  const FilterSource();
}

/// A Hagezi list, at [path] under the DNS blocklist's mirrors.
final class HageziFile extends FilterSource {
  const HageziFile(this.path);
  final String path;
}

/// A list at fixed [urls], tried in order.
final class FixedUrls extends FilterSource {
  const FixedUrls(this.urls);
  final List<String> urls;
}

/// The lists a download fetches with the rows and drops them through
/// (SUGGEST-009): adult, gambling and pop-up sites, which otherwise rank among
/// the first for a short prefix, and the most abused top-level domains, less
/// the sites on them [allow] names. A filter's [allow] list exempts rows from
/// its own [block] list only.
enum TopSitesFilter {
  nsfw(HageziFile('wildcard/nsfw-onlydomains.txt')),
  porn(FixedUrls([
    'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts',
    'https://cdn.jsdelivr.net/gh/StevenBlack/hosts@master/alternates/porn-only/hosts',
  ])),
  // The mini cut drops as many of the top rows as the whole list does, at a
  // fifth of its size.
  gambling(HageziFile('wildcard/gambling.mini-onlydomains.txt')),
  popups(HageziFile('wildcard/popupads-onlydomains.txt')),
  abusedTlds(
    HageziFile('wildcard/spam-tlds-onlydomains.txt'),
    allow: HageziFile('wildcard/spam-tlds-allow-onlydomains.txt'),
    tlds: true,
  );

  const TopSitesFilter(this.block, {this.allow, this.tlds = false});

  final FilterSource block;
  final FilterSource? allow;

  /// Whether [block] names whole top-level domains rather than sites.
  final bool tlds;
}

/// A [TopSitesFilter]'s lists as fetched; [allow] is empty where it has none.
typedef FilterLists = ({String block, String allow});

/// Words the list filters wherever a host carries them (SUGGEST-009): adult
/// sites no [TopSitesFilter] has named yet. A rare site that only contains one
/// (`aiimsexams.ac.in`, `xxxlutz.de`) is filtered with them.
const List<String> kTopSitesFilteredWords = [
  'porn',
  'xxx',
  'sex',
  'hentai',
  'jizz',
  'xvideos',
  'xnxx',
  'xhamster',
  'nsfw',
  'milf',
  'nude',
  'erotic',
  'escort',
  'fap',
  'beeg',
  'redtube',
  'tube8',
  'spankbang',
  'brazzers',
  'rule34',
  'chaturbate',
  'stripchat',
  'bongacam',
  'livejasmin',
  'camsoda',
  'cam4',
  'onlyfans',
  'yadong',
  'maal',
  'doujin',
  'yaoi',
  'erotik',
  'mydesi',
  'boob',
  'lewd',
  'naked',
  'pussy',
  'fetish',
  'bdsm',
  'swinger',
  'hookup',
];

/// Second-level labels under which a site's name is the third label from
/// the end (`co.uk`, `com.br`), near enough to tell one site's hostnames.
const Set<String> _secondLevels = {
  'ac',
  'co',
  'com',
  'edu',
  'go',
  'gob',
  'gouv',
  'gov',
  'mil',
  'ne',
  'net',
  'nic',
  'or',
  'org',
};

/// Leading labels a site is also served under, merged into the site.
const List<String> _aliasLabels = ['www.', 'm.'];

/// The rows of a CrUX list [csv] up to [kTopSitesRank], as `(origin, rank)`.
/// Only lines a newline ends count, so a download cut mid-line loses that
/// line and nothing else; the header and any row that does not parse are
/// skipped.
Iterable<(String, int)> _rows(String csv) sync* {
  var start = 0;
  for (var end = csv.indexOf('\n'); end >= 0; end = csv.indexOf('\n', start)) {
    final line = csv.substring(start, end).trim();
    start = end + 1;
    final comma = line.lastIndexOf(',');
    if (comma < 0) continue;
    final rank = int.tryParse(line.substring(comma + 1));
    if (rank == null) continue;
    if (rank > kTopSitesRank) return;
    yield (line.substring(0, comma), rank);
  }
}

/// The part of a CrUX list [csv] a [TopSites] reads, as CSV, less the rows
/// one of [filters] drops (a domain list or a hosts file each): what the
/// service stores, so the list is read again through [TopSites.fromCrux] and
/// its filter on every load. A list's lines are only matched against the
/// rows' hosts, so a large list is never held whole.
String cruxHead(String csv, {List<FilterLists> filters = const []}) {
  final rows = [
    for (final (origin, rank) in _rows(csv))
      (origin, rank, Uri.tryParse(origin)?.host.toLowerCase() ?? ''),
  ];
  final suffixes = {for (final (_, _, host) in rows) ..._suffixes(host)};
  Set<String> named(String list) => {
        for (final domain in listedDomains(list))
          if (suffixes.contains(domain)) domain,
      };
  final lists = [
    for (final f in filters) (block: named(f.block), allow: named(f.allow)),
  ];
  bool dropped(String host) {
    final up = _suffixes(host).toList();
    return lists
        .any((f) => up.any(f.block.contains) && !up.any(f.allow.contains));
  }

  return [
    for (final (origin, rank, host) in rows)
      if (!dropped(host)) '$origin,$rank\n',
  ].join();
}

/// [host] and each domain above it: `a.b.c`, `b.c`, `c`.
Iterable<String> _suffixes(String host) sync* {
  for (var at = 0;; at = host.indexOf('.', at) + 1) {
    yield host.substring(at);
    if (!host.contains('.', at)) return;
  }
}

/// The site [host] belongs to: its last two labels, or three under one of
/// [_secondLevels].
String _siteOf(String host) {
  final labels = host.split('.');
  if (labels.length < 3) return host;
  final take = _secondLevels.contains(labels[labels.length - 2]) ? 3 : 2;
  return labels.sublist(labels.length - take).join('.');
}

/// The host [origin] names as a site, or null where the list does not offer
/// it: not https on its default port, filtered, or a bare name. A `www.` or
/// `m.` label is dropped.
String? _siteHost(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.scheme != 'https' || uri.port != 443) return null;
  var host = uri.host.toLowerCase();
  for (final alias in _aliasLabels) {
    final rest = host.startsWith(alias) ? host.substring(alias.length) : null;
    if (rest != null && rest.contains('.')) host = rest;
  }
  final dot = host.lastIndexOf('.');
  if (dot <= 0) return null;
  if (kTopSitesFilteredTlds.contains(host.substring(dot + 1))) return null;
  if (kTopSitesFilteredWords.any(host.contains)) return null;
  return host;
}

/// What [typed] asks the list for: the address it begins, without a scheme
/// or a `www.`, or null where it is shorter than [kTopSitesMinTyped].
String? _typed(String typed) {
  var text = typed.trim().toLowerCase();
  for (final prefix in const ['https://', 'http://', 'www.']) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  return text.length < kTopSitesMinTyped ? null : text;
}

/// Whether [text] can begin a host: no path, port, query or space.
bool _beginsHost(String text) => !text.contains(RegExp(r'[/:?#\s]'));

/// [url], a site's home, as the list writes an address: its host without a
/// `www.` or `m.` label, then its path without a trailing `/`.
String siteAddress(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return url.trim().toLowerCase();
  var host = uri.host.toLowerCase();
  for (final alias in _aliasLabels) {
    final rest = host.startsWith(alias) ? host.substring(alias.length) : null;
    if (rest != null && rest.contains('.')) host = rest;
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '$host$path';
}

/// The popular sites, one host each, best first: by rank group; within a
/// group, CrUX gives no order, so the site the list names under more
/// hostnames comes first (google.com before a site with one), then the
/// shorter host, then alphabetically.
final class TopSites {
  const TopSites._(this._hosts);

  static const TopSites empty = TopSites._([]);

  factory TopSites.fromCrux(String csv) {
    final rows = _rows(csv).toList();
    final hostnames = <String, int>{};
    for (final (origin, _) in rows) {
      final host = Uri.tryParse(origin)?.host.toLowerCase() ?? '';
      if (host.isEmpty) continue;
      hostnames.update(_siteOf(host), (n) => n + 1, ifAbsent: () => 1);
    }
    final best = <String, int>{};
    for (final (origin, rank) in rows) {
      final host = _siteHost(origin);
      if (host == null) continue;
      final seen = best[host];
      if (seen == null || rank < seen) best[host] = rank;
    }
    final breadth = {
      for (final host in best.keys) host: hostnames[_siteOf(host)] ?? 0,
    };
    final hosts = best.keys.toList()
      ..sort((a, b) {
        final byRank = best[a]!.compareTo(best[b]!);
        if (byRank != 0) return byRank;
        final byBreadth = breadth[b]!.compareTo(breadth[a]!);
        if (byBreadth != 0) return byBreadth;
        final byLength = a.length.compareTo(b.length);
        return byLength != 0 ? byLength : a.compareTo(b);
      });
    return TopSites._(List.unmodifiable(hosts));
  }

  final List<String> _hosts;

  int get length => _hosts.length;

  bool get isEmpty => _hosts.isEmpty;

  /// Up to [kTopSitesShown] addresses that begin with what [typed] names:
  /// a [kTopSitesPinned] one first, then hosts, best first. An address typed
  /// out whole, or one of [added] (as [siteAddress] writes a site's home),
  /// is not offered; an empty list offers nothing.
  List<String> match(String typed, {Set<String> added = const {}}) {
    final prefix = _typed(typed);
    if (prefix == null || _hosts.isEmpty) return const [];
    bool offered(String address) =>
        address.length > prefix.length && !added.contains(address);
    final found = <String>[
      for (final pin in kTopSitesPinned)
        if (offered(pin.address) &&
            (pin.address.startsWith(prefix) ||
                pin.words.any((w) => w.startsWith(prefix))))
          pin.address,
    ];
    if (!_beginsHost(prefix)) return found.take(kTopSitesShown).toList();
    for (final host in _hosts) {
      if (found.length >= kTopSitesShown) break;
      if (offered(host) && host.startsWith(prefix)) found.add(host);
    }
    return found;
  }
}
