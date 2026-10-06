import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/opensearch_engine.dart';

// Descriptions as the engines serve them (fetched 2026-10-06), trimmed to the
// elements the parser reads plus their neighbours.

const _searxPost = '''<?xml version="1.0" encoding="utf-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/" xmlns:moz="http://www.mozilla.org/2006/browser/search/">
  <ShortName>Searx Belgium</ShortName>
  <Description>SearXNG is a metasearch engine that respects your privacy.</Description>
  <Url rel="results" type="text/html" method="POST" template="https://searx.be/search">
    <Param name="q" value="{searchTerms}" />
  </Url>
  <Url rel="suggestions" type="application/x-suggestions+json" method="POST" template="https://searx.be/autocompleter?q={searchTerms}"/>
  <Url rel="self" type="application/opensearchdescription+xml" method="POST" template="https://searx.be/opensearch.xml" />
  <moz:SearchForm>https://searx.be/search</moz:SearchForm>
</OpenSearchDescription>''';

const _searxGet = '''<?xml version="1.0" encoding="utf-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>PrivAU</ShortName>
  <Url rel="suggestions" type="application/x-suggestions+json" method="GET" template="https://priv.au/autocompleter?q={searchTerms}"/>
  <Url rel="results" type="text/html" method="GET" template="https://priv.au/search?q={searchTerms}"/>
</OpenSearchDescription>''';

const _qwant = '''<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>Qwant</ShortName>
  <Url type="application/x-suggestions+json" method="GET" template="https://api.qwant.com/v3/suggest/?q={searchTerms}&amp;client=opensearch" />
  <Url type="text/html" method="GET" template="https://www.qwant.com?q={searchTerms}&amp;client=opensearch" />
</OpenSearchDescription>''';

const _mojeek = '''<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
	<ShortName>Mojeek</ShortName>
	<Url type="text/html" template="https://www.mojeek.com/search?q={searchTerms}"></Url>
</OpenSearchDescription>''';

const _ddgHtml = '''<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <ShortName>DuckDuckGo HTML</ShortName>
  <Url type="text/html" method="post" template="https://html.duckduckgo.com/html/">
    <Param name="q" value="{searchTerms}"/>
  </Url>
</OpenSearchDescription>''';

String? _address(String xml, {bool postAsGet = false, String? from}) =>
    searchAddressFromDescription(
      xml,
      descriptionUrl: Uri.parse(from ?? 'https://example.org/opensearch.xml'),
      postAsGet: postAsGet,
    );

String _description(String url) => '''<?xml version="1.0"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="$url"/>
</OpenSearchDescription>''';

void main() {
  group('searchAddressFromDescription', () {
    test('a GET results URL', () {
      expect(_address(_searxGet), 'https://priv.au/search?q=%s');
      expect(_address(_mojeek), 'https://www.mojeek.com/search?q=%s');
      expect(_address(_qwant), 'https://www.qwant.com?q=%s&client=opensearch',
          reason: 'the suggestions URL before it is not a results URL');
    });

    test('a POST results URL only for an engine that answers GET', () {
      expect(_address(_searxPost), isNull);
      expect(_address(_searxPost, postAsGet: true),
          'https://searx.be/search?q=%s');
      expect(_address(_ddgHtml), isNull);
    });

    test('parameters the spec defines are filled, optional ones dropped', () {
      expect(
        _address(_description(
            'https://s.example/find?q={searchTerms}&amp;ie={inputEncoding}'
            '&amp;lang={language}&amp;page={startPage?}&amp;n={count?}')),
        'https://s.example/find?q=%s&ie=UTF-8&lang=*',
      );
    });

    test('a required parameter nothing can fill makes the URL unusable', () {
      expect(_address(_description('https://s.example/?q={searchTerms}&amp;k={apiKey}')),
          isNull);
    });

    test('a URL without the query, or not http(s), is not one', () {
      expect(_address(_description('https://s.example/browse')), isNull);
      expect(_address(_description('javascript:alert({searchTerms})')), isNull);
      expect(_address(_description('ftp://s.example/?q={searchTerms}')), isNull);
    });

    test('a relative template resolves against the description', () {
      expect(
        _address(_description('/search?q={searchTerms}'),
            from: 'https://searx.lan/opensearch.xml'),
        'https://searx.lan/search?q=%s',
      );
    });

    test('malformed XML is no description', () {
      expect(_address('<OpenSearchDescription><Url'), isNull);
      expect(_address('not xml at all'), isNull);
    });
  });

  group('PageSearchReport', () {
    test('reads the shim\'s report and drops malformed entries', () {
      final r = PageSearchReport.from({
        'generator': 'searxng/2026.7.20',
        'links': [
          {'href': 'https://searx.be/opensearch.xml', 'title': 'Searx Belgium'},
          {'href': 42},
          'junk',
        ],
      })!;
      expect(r.links.map((l) => l.href), ['https://searx.be/opensearch.xml']);
      expect(r.isSearx, isTrue);
      expect(PageSearchReport.from('nope'), isNull);
    });

    test('only SearXNG and searx count as searching the web', () {
      bool searx(String g) =>
          PageSearchReport(links: const [], generator: g).isSearx;
      expect(searx('searxng/2026.10.5+111e3b0ff'), isTrue);
      expect(searx('searx/1.1.0'), isTrue);
      expect(searx('SearXNG'), isTrue);
      expect(searx('WordPress 6.6'), isFalse);
      expect(searx('searxify'), isFalse);
      expect(searx(''), isFalse);
    });
  });

  group('discoverPageSearch', () {
    Future<DiscoveredSearch?> discover(
      List<String> hrefs, {
      String generator = '',
      String documentUrl = 'https://searx.lan/search?q=x',
      String siteUrl = 'https://searx.lan/',
      Map<String, String> served = const {},
      List<String>? fetched,
    }) =>
        discoverPageSearch(
          PageSearchReport(
            generator: generator,
            links: [for (final h in hrefs) OpenSearchLink(href: h, title: '')],
          ),
          documentUrl: documentUrl,
          siteUrl: siteUrl,
          fetch: (url) async {
            fetched?.add(url.toString());
            final body = served[url.toString()];
            return body == null ? null : Uint8List.fromList(utf8.encode(body));
          },
        );

    test('a SearXNG instance searches the web through its own address',
        () async {
      final found = await discover(
        ['https://searx.lan/opensearch.xml?method=POST'],
        generator: 'searxng/2026.7.20',
        served: {
          'https://searx.lan/opensearch.xml?method=POST': _searxPost
              .replaceAll('https://searx.be/', 'https://searx.lan/'),
        },
      );
      expect(found!.address, 'https://searx.lan/search?q=%s');
      expect(found.web, isTrue);
    });

    test('any other page offers searching itself only', () async {
      final found = await discover(
        ['https://www.mojeek.com/opensearch.xml'],
        documentUrl: 'https://www.mojeek.com/',
        siteUrl: 'https://mojeek.com/',
        served: {'https://www.mojeek.com/opensearch.xml': _mojeek},
      );
      expect(found!.address, 'https://www.mojeek.com/search?q=%s');
      expect(found.web, isFalse);
    });

    test('a description off the site\'s domain is never fetched', () async {
      final fetched = <String>[];
      final found = await discover(
        ['https://tracker.example.net/osd.xml'],
        fetched: fetched,
        served: {'https://tracker.example.net/osd.xml': _searxGet},
      );
      expect(found, isNull);
      expect(fetched, isEmpty);
    });

    test('an address off the site\'s domain is not taken', () async {
      final found = await discover(
        ['https://searx.lan/opensearch.xml'],
        generator: 'searxng/1',
        served: {'https://searx.lan/opensearch.xml': _searxGet},
      );
      expect(found, isNull, reason: 'the description points at priv.au');
    });

    test('a page outside the site reports nothing for it', () async {
      final fetched = <String>[];
      final found = await discover(
        ['https://other.example/opensearch.xml'],
        documentUrl: 'https://other.example/',
        fetched: fetched,
      );
      expect(found, isNull);
      expect(fetched, isEmpty);
    });

    test('a link that fails falls through to the next', () async {
      final found = await discover(
        ['https://searx.lan/missing.xml', 'https://searx.lan/opensearch.xml'],
        served: {
          'https://searx.lan/opensearch.xml':
              _description('https://searx.lan/search?q={searchTerms}'),
        },
      );
      expect(found!.address, 'https://searx.lan/search?q=%s');
    });
  });
}
