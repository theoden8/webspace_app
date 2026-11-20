import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/userscript_header.dart';

/// US-009: which URLs a header's patterns name. The rows are Chrome's
/// documented match-pattern examples and Tampermonkey's include forms; each
/// planted mistake below is the compiler with one fault, and must fail a row.
///
/// The URLs are tested here with Dart's RegExp over the compiled sources;
/// the page tests the same sources with its own engine
/// (test/js/userscript_gate.test.js).

typedef _Row = ({List<String> lines, String url, bool runs});

UserscriptHeader _header(List<String> lines) => parseUserscriptHeader(
  ['// ==UserScript==', ...lines, '// ==/UserScript=='].join('\n'),
);

bool _tests(UrlPattern p, {required String url}) => RegExp(
  p.source,
  caseSensitive: !p.flags.contains('i'),
  multiLine: p.flags.contains('m'),
  dotAll: p.flags.contains('s'),
  unicode: p.flags.contains('u'),
).hasMatch(url);

bool _runs(UserscriptHeader h, {required String url}) =>
    switch (h.include) {
      EveryPage() => true,
      NamedPages(:final patterns) => patterns.any((p) => _tests(p, url: url)),
    } &&
    !h.exclude.any((p) => _tests(p, url: url));

_Row _row(String line, {required String url, required bool runs}) =>
    (lines: ['// @$line'], url: url, runs: runs);

final List<_Row> _table = [
  // Chrome: https://*/*
  _row('match https://*/*', url: 'https://www.google.com/', runs: true),
  _row(
    'match https://*/*',
    url: 'https://example.org/foo/bar.html',
    runs: true,
  ),
  _row('match https://*/*', url: 'http://example.org/', runs: false),
  // Chrome: https://*/foo*
  _row(
    'match https://*/foo*',
    url: 'https://example.com/foo/bar.html',
    runs: true,
  ),
  _row('match https://*/foo*', url: 'https://www.google.com/foo', runs: true),
  _row('match https://*/foo*', url: 'https://www.google.com/', runs: false),
  _row(
    'match https://*/foo*',
    url: 'https://www.google.com/bar/foo',
    runs: false,
  ),
  // Chrome: https://*.google.com/foo*bar
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://www.google.com/foo/baz/bar',
    runs: true,
  ),
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://docs.google.com/foobar',
    runs: true,
  ),
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://google.com/foobar',
    runs: true,
  ),
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://www.google.com/foo',
    runs: false,
  ),
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://www.google.com/foobarbaz',
    runs: false,
  ),
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://evilgoogle.com/foobar',
    runs: false,
  ),
  _row(
    'match https://*.google.com/foo*bar',
    url: 'https://google.com.evil.io/foobar',
    runs: false,
  ),
  // Chrome: file:///foo*
  _row('match file:///foo*', url: 'file:///foo/bar.html', runs: true),
  _row('match file:///foo*', url: 'file:///foo', runs: true),
  _row('match file:///foo*', url: 'file:///bar/foo', runs: false),
  // Chrome: http://127.0.0.1/*
  _row('match http://127.0.0.1/*', url: 'http://127.0.0.1/', runs: true),
  _row(
    'match http://127.0.0.1/*',
    url: 'http://127.0.0.1/foo/bar.html',
    runs: true,
  ),
  _row('match http://127.0.0.1/*', url: 'http://127.0.0.10/', runs: false),
  _row('match http://127.0.0.1/*', url: 'http://127a0a0a1/', runs: false),
  // Chrome: *://mail.google.com/*
  _row(
    'match *://mail.google.com/*',
    url: 'http://mail.google.com/foo/baz/bar',
    runs: true,
  ),
  _row(
    'match *://mail.google.com/*',
    url: 'https://mail.google.com/foobar',
    runs: true,
  ),
  _row(
    'match *://mail.google.com/*',
    url: 'file://mail.google.com/foobar',
    runs: false,
  ),
  _row(
    'match *://mail.google.com/*',
    url: 'ftp://mail.google.com/foobar',
    runs: false,
  ),
  // Chrome: <all_urls>
  _row('match <all_urls>', url: 'http://example.org/foo/bar.html', runs: true),
  _row('match <all_urls>', url: 'file:///bar/baz.html', runs: true),
  // Chrome's invalid patterns name no page.
  _row(
    'match https://www.google.com',
    url: 'https://www.google.com/',
    runs: false,
  ),
  _row('match https://*foo/bar', url: 'https://xfoo/bar', runs: false),
  _row(
    'match https://foo.*.bar/baz',
    url: 'https://foo.x.bar/baz',
    runs: false,
  ),
  _row('match http:/bar', url: 'http://bar/', runs: false),
  _row('match foo://*', url: 'foo://x/', runs: false),
  // US-009's scenarios.
  _row(
    'match https://*.example.com/watch*',
    url: 'https://www.example.com/watch?v=1',
    runs: true,
  ),
  _row(
    'match https://*.example.com/watch*',
    url: 'https://www.example.com/feed',
    runs: false,
  ),
  _row(
    'match https://*.example.com/*',
    url: 'https://evil-example.com/',
    runs: false,
  ),
  (
    lines: [
      '// @match https://example.com/*',
      '// @exclude-match https://example.com/admin/*',
    ],
    url: 'https://example.com/admin/users',
    runs: false,
  ),
  (
    lines: [
      '// @match https://example.com/*',
      '// @exclude-match https://example.com/admin/*',
    ],
    url: 'https://example.com/home',
    runs: true,
  ),
  // A port is any port; a user name cannot pose as the host.
  _row(
    'match https://example.com/*',
    url: 'https://example.com:8443/a',
    runs: true,
  ),
  _row(
    'match https://*.example.com/*',
    url: 'https://example.com@evil.io/',
    runs: false,
  ),
  // Tampermonkey's @include: a glob over the whole URL, or a /regex/.
  _row(
    'include https://example.com/*',
    url: 'https://example.com/a.b',
    runs: true,
  ),
  _row(
    'include https://example.com/*',
    url: 'https://exampleXcom/',
    runs: false,
  ),
  _row('include *example.com*', url: 'https://www.example.com/x', runs: true),
  _row('include *example.com*', url: 'https://www.example.org/x', runs: false),
  _row(
    r'include /^https:\/\/example\.com\/a/',
    url: 'https://example.com/a/1',
    runs: true,
  ),
  _row(
    r'include /^https:\/\/example\.com\/a/',
    url: 'https://example.com/b/1',
    runs: false,
  ),
  _row(
    r'include /^HTTPS:\/\/EXAMPLE\.COM\//i',
    url: 'https://example.com/',
    runs: true,
  ),
  _row(
    r'include /^https:\/\/example\.com\//g',
    url: 'https://example.com/',
    runs: false,
  ),
  (
    lines: ['// @include https://example.com/*', '// @exclude *://*/private*'],
    url: 'https://example.com/private/1',
    runs: false,
  ),
  // A header naming no page runs everywhere.
  (lines: ['// @name Any'], url: 'https://anything.example/', runs: true),
];

UrlPattern _rewrite(UrlPattern p, {required String Function(String) f}) =>
    (source: f(p.source), flags: p.flags);

UserscriptHeader _mapPatterns(
  UserscriptHeader h, {
  required String Function(String) f,
}) => (
  name: h.name,
  include: switch (h.include) {
    EveryPage() => const EveryPage(),
    NamedPages(:final patterns) => NamedPages([
      for (final p in patterns) _rewrite(p, f: f),
    ]),
  },
  exclude: [for (final p in h.exclude) _rewrite(p, f: f)],
  runAt: h.runAt,
  notProvided: h.notProvided,
  problems: h.problems,
);

/// Planted mistakes, each the compiler with one fault (design D6).
final Map<String, UserscriptHeader Function(List<String>)> _planted = {
  'host * crossing dots': (lines) => _mapPatterns(
    _header(lines),
    f: (s) => s.replaceAll(r'(?:[^/?#:]+\.)?', r'[^/?#:]*'),
  ),
  'scheme * matching file:': (lines) => _mapPatterns(
    _header(lines),
    f: (s) => s.replaceFirst(r'^https?://', r'^(?:https?|file)://'),
  ),
  'path anchor dropped': (lines) => _mapPatterns(
    _header(lines),
    f: (s) => s.endsWith(r'$') ? s.substring(0, s.length - 1) : s,
  ),
  'glob not escaping .': (lines) =>
      _mapPatterns(_header(lines), f: (s) => s.replaceAll(r'\.', '.')),
  'exclusion losing to inclusion': (lines) {
    final h = _header(lines);
    return (
      name: h.name,
      include: h.include,
      exclude: const <UrlPattern>[],
      runAt: h.runAt,
      notProvided: h.notProvided,
      problems: h.problems,
    );
  },
};

void main() {
  for (final row in _table) {
    test(
      'US-009: ${row.lines.join(' ')} ${row.runs ? 'runs on' : 'skips'} ${row.url}',
      () {
        expect(_runs(_header(row.lines), url: row.url), row.runs);
      },
    );
  }

  for (final MapEntry(key: mistake, value: header) in _planted.entries) {
    test('US-009: the table catches the planted mistake: $mistake', () {
      final failing = [
        for (final row in _table)
          if (_runs(header(row.lines), url: row.url) != row.runs) row.url,
      ];
      expect(failing, isNotEmpty);
    });
  }

  test('US-009: an invalid pattern is reported with its line', () {
    final h = _header(['// @match https://example.com']);
    expect(h.problems, hasLength(1));
    expect((h.problems.single as InvalidPattern).entry, (
      key: 'match',
      value: 'https://example.com',
    ));
  });
}
