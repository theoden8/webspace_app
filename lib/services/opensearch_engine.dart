/// OpenSearch autodiscovery (LIR-035): what a page says about its own search,
/// and the search address its OpenSearch description gives.
///
/// A page declares its search with `<link rel="search"
/// type="application/opensearchdescription+xml" href=...>`; the description
/// names a results URL with `{searchTerms}` where the query goes. Browsers add
/// search engines this way, and every SearXNG instance declares one, so this
/// is how a site the table in `web_search_engine.dart` does not know learns to
/// search. Pure Dart: the watcher shim reports, the webview fetches, this
/// file decides.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'package:webspace/services/web_search_engine.dart'
    show WebSearchEngine, kSearchQueryToken;

/// Largest OpenSearch description read, in bytes. Real ones are under 4 KiB.
const int kMaxOpenSearchBytes = 64 * 1024;

/// A search address a site's page declared.
class DiscoveredSearch {
  final String address;

  /// Whether it searches the whole web: only a SearXNG or searx instance is
  /// taken to, so any other page can offer searching itself and no more.
  final bool web;

  const DiscoveredSearch({required this.address, required this.web});
}

/// Where a site's root webview reports the search its pages declare. Set only
/// for a site that has no address of its own and is not a known host.
class SiteSearchTarget {
  const SiteSearchTarget({
    required this.siteUrl,
    required this.enabled,
    required this.onSearch,
  });

  /// The site's home, whose domain a declared address must stay in.
  final String siteUrl;

  /// Read on every report: discovery runs only while web search is offered.
  final bool Function() enabled;
  final void Function(DiscoveredSearch search) onSearch;
}

/// One OpenSearch description a page linked, `href` resolved by the page.
class OpenSearchLink {
  final String href;
  final String title;

  const OpenSearchLink({required this.href, required this.title});
}

/// What the watcher shim reports about the top document.
class PageSearchReport {
  final List<OpenSearchLink> links;

  /// The page's `<meta name="generator">`, empty when it has none.
  final String generator;

  const PageSearchReport({required this.links, required this.generator});

  /// The report in [raw], the shim's handler argument, or null when it is not
  /// one. Entries of the wrong shape are dropped, not fatal: the page can
  /// edit what the shim reads.
  static PageSearchReport? from(Object? raw) {
    if (raw is! Map) return null;
    final generator = raw['generator'];
    final links = raw['links'];
    return PageSearchReport(
      generator: generator is String ? generator : '',
      links: [
        if (links is List)
          for (final l in links)
            if (l is Map && l['href'] is String)
              OpenSearchLink(
                href: l['href'] as String,
                title: l['title'] is String ? l['title'] as String : '',
              ),
      ],
    );
  }

  /// Whether the page is a SearXNG (or searx) instance, which searches the
  /// whole web and takes `site:`. Both stamp every page with their name and
  /// version (`searxng/2026.7.20`).
  bool get isSearx => RegExp(
    r'^searx(ng)?(/|\s|$)',
    caseSensitive: false,
  ).hasMatch(generator.trim());
}

/// The search address the OpenSearch description [xml] gives, with `%s` for
/// the query, or null when it gives none this app can use.
///
/// The address is the first `text/html` URL meant for results. A `POST` one
/// is used only when [postAsGet] is set, for engines that answer the same
/// query by `GET` (SearXNG does; its description says `POST` when the instance
/// prefers it). Template parameters the spec gives a value for are filled
/// in; optional ones are dropped; any other required one makes the URL
/// unusable, since nothing here can fill it.
String? searchAddressFromDescription(
  String xml, {
  required Uri descriptionUrl,
  bool postAsGet = false,
}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }
  for (final url in doc.descendants.whereType<XmlElement>()) {
    if (url.localName != 'Url') continue;
    if (url.getAttribute('type')?.trim().toLowerCase() != 'text/html') {
      continue;
    }
    final rel = (url.getAttribute('rel') ?? 'results').toLowerCase();
    if (!rel.split(RegExp(r'\s+')).contains('results')) continue;
    final method = (url.getAttribute('method') ?? 'GET').trim().toUpperCase();
    if (method != 'GET' && !(method == 'POST' && postAsGet)) continue;
    final template = url.getAttribute('template');
    if (template == null || template.trim().isEmpty) continue;
    final params = [
      for (final p in url.childElements)
        if (p.localName == 'Param' && (p.getAttribute('name') ?? '').isNotEmpty)
          (name: p.getAttribute('name')!, value: p.getAttribute('value') ?? ''),
    ];
    final address = _address(template.trim(), params, descriptionUrl);
    if (address != null) return address;
  }
  return null;
}

final RegExp _templateParam = RegExp(r'\{([^{}]+)\}');

/// Values OpenSearch 1.1 defines for the parameters a results URL may carry.
const Map<String, String> _filled = {
  'inputEncoding': 'UTF-8',
  'outputEncoding': 'UTF-8',
  'language': '*',
  'startIndex': '1',
  'startPage': '1',
};

String? _address(
  String template,
  List<({String name, String value})> params,
  Uri descriptionUrl,
) {
  final Uri base;
  try {
    base = descriptionUrl.resolve(template);
  } on FormatException {
    return null;
  }
  if (base.scheme != 'http' && base.scheme != 'https') return null;
  if (base.host.isEmpty) return null;

  var hasQuery = false;
  String? fill(String value) {
    final out = StringBuffer();
    var last = 0;
    for (final m in _templateParam.allMatches(value)) {
      out.write(Uri.encodeQueryComponent(value.substring(last, m.start)));
      last = m.end;
      final name = m.group(1)!;
      if (name == 'searchTerms') {
        out.write(kSearchQueryToken);
        hasQuery = true;
      } else if (_filled.containsKey(name)) {
        out.write(_filled[name]);
      } else if (name.endsWith('?')) {
        return null;
      } else {
        throw const FormatException('required parameter');
      }
    }
    out.write(Uri.encodeQueryComponent(value.substring(last)));
    return out.toString();
  }

  try {
    final pairs = <String>[];
    for (final pair in base.query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final name = eq < 0 ? pair : pair.substring(0, eq);
      final raw = eq < 0
          ? ''
          : Uri.decodeQueryComponent(pair.substring(eq + 1));
      final value = fill(raw);
      if (value == null) continue;
      pairs.add('$name=$value');
    }
    for (final p in params) {
      final value = fill(p.value);
      if (value == null) continue;
      pairs.add('${Uri.encodeQueryComponent(p.name)}=$value');
    }
    if (!hasQuery) return null;
    final head = base
        .removeFragment()
        .replace(query: '')
        .toString()
        .replaceFirst(RegExp(r'\?$'), '');
    return '$head?${pairs.join('&')}';
  } on FormatException {
    return null;
  }
}

/// The search a page of the site at [siteUrl] declared in [report], or null.
///
/// Only the page's own descriptions count: a link outside the site's domain
/// is not read, and an address outside it is not taken (see
/// [WebSearchEngine.acceptsDiscovered]). [fetch] reads a description through
/// the site's proxy and blockers, at most [kMaxOpenSearchBytes].
Future<DiscoveredSearch?> discoverPageSearch(
  PageSearchReport report, {
  required String documentUrl,
  required String siteUrl,
  required Future<Uint8List?> Function(Uri description) fetch,
}) async {
  final document = Uri.tryParse(documentUrl);
  if (document == null || !WebSearchEngine.inDomainOf(document, siteUrl)) {
    return null;
  }
  for (final link in report.links) {
    final href = Uri.tryParse(link.href);
    if (href == null || (href.scheme != 'http' && href.scheme != 'https')) {
      continue;
    }
    if (!WebSearchEngine.inDomainOf(href, siteUrl)) continue;
    final bytes = await fetch(href);
    if (bytes == null) continue;
    final address = searchAddressFromDescription(
      utf8.decode(bytes, allowMalformed: true),
      descriptionUrl: href,
      postAsGet: report.isSearx,
    );
    if (address == null ||
        !WebSearchEngine.acceptsDiscovered(address, siteUrl)) {
      continue;
    }
    return DiscoveredSearch(address: address, web: report.isSearx);
  }
  return null;
}
