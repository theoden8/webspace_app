import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/userscript_header.dart';
import 'package:webspace/settings/user_script.dart';

/// US-008: the header is the first `// ==UserScript==` block of the full
/// source, read each build. The table runs against the parser and against
/// each planted mistake kept below, which must fail at least one row.

/// What a header reads as, in a form two parses can be compared by.
String _shape(UserscriptHeader h) => [
      'name=${h.name}',
      'include=${switch (h.include) {
        EveryPage() => 'every',
        NamedPages(:final patterns) =>
          patterns.map((p) => '${p.source}/${p.flags}').join(','),
      }}',
      'exclude=${h.exclude.map((p) => '${p.source}/${p.flags}').join(',')}',
      'runAt=${h.runAt}',
      'notProvided=${h.notProvided.map((e) => '${e.key} ${e.value}').join(',')}',
      'problems=${h.problems.map(_problem).join(',')}',
    ].join(';');

String _problem(HeaderProblem p) => switch (p) {
      HeaderUnclosed() => 'unclosed',
      InvalidPattern(:final entry) => 'invalid ${entry.key} ${entry.value}',
      UnknownRunAt(:final value) => 'run-at $value',
    };

String _block(List<String> lines) =>
    ['// ==UserScript==', ...lines, '// ==/UserScript=='].join('\n');

typedef _Row = ({
  String why,
  String source,
  bool Function(UserscriptHeader h) holds,
});

final _library = _block([
  '// @name Library',
  '// @match https://example.com/a/*',
]);
final _ownCode = _block([
  '// @name Own',
  '// @match https://example.com/b/*',
]);

/// The full source of a script with a URL: the library, then the user's code.
String _full(String library, {required String own}) => '$library\n$own';

final List<_Row> _table = [
  (
    why: 'US-008: the library\'s header wins over the user\'s code',
    source: _full(_library, own: _ownCode),
    holds: (h) => h.name == 'Library',
  ),
  (
    why: 'US-008: a header in the user\'s own code is read',
    source: '${_block(['// @name Tidy'])}\nconsole.log(1);',
    holds: (h) => h.name == 'Tidy',
  ),
  (
    why: 'US-008: an unclosed block is no header and is reported',
    source: '// ==UserScript==\n// @name Half\n// @match https://a.example/*',
    holds: (h) =>
        h.name == null &&
        h.include is EveryPage &&
        h.problems.single is HeaderUnclosed,
  ),
  (
    why: 'US-008: a source with no block is no header',
    source: 'document.body.style.background = "red";',
    holds: (h) => _shape(h) == _shape(noHeader),
  ),
  (
    why: 'US-008: a key may repeat',
    source: _block([
      '// @match https://a.example/*',
      '// @match https://b.example/*',
      '// @exclude https://a.example/x*',
    ]),
    holds: (h) =>
        (h.include as NamedPages).patterns.length == 2 && h.exclude.length == 1,
  ),
  (
    why: 'US-008: indentation, tabs and CRLF are read',
    source: '  //\t==UserScript==\r\n  //   @name   Spaced  \r\n//\t==/UserScript==\r\n',
    holds: (h) => h.name == 'Spaced',
  ),
  (
    why: 'US-008: only the first block is read',
    source: '${_block(['// @name First'])}\n${_block(['// @name Second'])}',
    holds: (h) => h.name == 'First',
  ),
  (
    why: 'US-009: a header naming no page runs on every page',
    source: _block(['// @name Any']),
    holds: (h) => h.include is EveryPage,
  ),
  (
    why: 'US-009: an invalid pattern names no page and is reported',
    source: _block(['// @match https://example.com']),
    holds: (h) =>
        h.include is NamedPages &&
        (h.include as NamedPages).patterns.isEmpty &&
        h.problems.single is InvalidPattern,
  ),
  (
    why: 'US-010: document-start moves a script to the start',
    source: _block(['// @run-at document-start']),
    holds: (h) => h.runAt == UserScriptInjectionTime.atDocumentStart,
  ),
  (
    why: 'US-010: document-idle and document-body run at the end',
    source: _block(['// @run-at document-idle']),
    holds: (h) => h.runAt == UserScriptInjectionTime.atDocumentEnd,
  ),
  (
    why: 'US-010: an unknown run-at keeps the stored time and is reported',
    source: _block(['// @run-at context-menu']),
    holds: (h) =>
        h.runAt == null &&
        h.problems.single is UnknownRunAt &&
        (h.problems.single as UnknownRunAt).value == 'context-menu',
  ),
  (
    why: 'US-012: GM grants and dependencies are reported as not provided',
    source: _block([
      '// @grant GM_xmlhttpRequest',
      '// @require https://code.jquery.com/jquery.min.js',
      '// @resource css https://example.com/a.css',
      '// @connect example.com',
      '// @updateURL https://example.com/x.meta.js',
      '// @downloadURL https://example.com/x.user.js',
    ]),
    holds: (h) => h.notProvided.map((e) => e.key).toList().join(',') ==
        'grant,require,resource,connect,updateURL,downloadURL',
  ),
  (
    why: 'US-012: @grant none is not reported',
    source: _block(['// @grant none']),
    holds: (h) => h.notProvided.isEmpty,
  ),
];

/// Planted mistakes: each is the parser with one fault, and must fail a row.
final Map<String, UserscriptHeader Function(String)> _planted = {
  'header taken from the user\'s code before the library': (source) {
    final at = source.lastIndexOf(RegExp(r'^[ \t]*//[ \t]*==UserScript==',
        multiLine: true));
    return parseUserscriptHeader(at < 0 ? source : source.substring(at));
  },
};

bool _passes(UserscriptHeader Function(String) parse) =>
    _table.every((row) => row.holds(parse(row.source)));

void main() {
  for (final row in _table) {
    test(row.why, () {
      expect(row.holds(parseUserscriptHeader(row.source)), isTrue,
          reason: _shape(parseUserscriptHeader(row.source)));
    });
  }

  for (final MapEntry(key: mistake, value: parse) in _planted.entries) {
    test('US-008: the table catches the planted mistake: $mistake', () {
      expect(_passes(parse), isFalse);
    });
  }

  test('US-008: no source text throws, and two parses agree', () {
    const seed = 20261120;
    final random = Random(seed);
    const pieces = [
      '// ==UserScript==', '// ==/UserScript==', '// @match ', '// @include ',
      '// @exclude ', '// @exclude-match ', '// @run-at ', '// @name ',
      '// @grant ', 'https://', '*://', '*.', '*', '/', '\\', '(', '[', '?',
      '<all_urls>', 'file:///', '\n', '\r\n', '\t', ' ', '//', '@', '==',
      'example.com', 'é', '\u0000', '\u{1F600}', '/x/gi', '/(/', '\$',
    ];
    final sources = [
      for (final row in _table) row.source,
    ];
    for (var i = 0; i < 10000; i++) {
      final String source;
      if (i.isEven) {
        source = [
          for (var j = random.nextInt(40); j > 0; j--)
            pieces[random.nextInt(pieces.length)],
        ].join();
      } else {
        final base = sources[random.nextInt(sources.length)].split('');
        for (var j = random.nextInt(6); j > 0 && base.isNotEmpty; j--) {
          final at = random.nextInt(base.length);
          switch (random.nextInt(3)) {
            case 0:
              base.removeAt(at);
            case 1:
              base.insert(at, pieces[random.nextInt(pieces.length)]);
            default:
              base[at] = String.fromCharCode(random.nextInt(0x3000));
          }
        }
        source = base.join();
      }
      final first = parseUserscriptHeader(source);
      final second = parseUserscriptHeader(source);
      expect(_shape(first), _shape(second), reason: 'seed $seed, case $i');
    }
  });
}
