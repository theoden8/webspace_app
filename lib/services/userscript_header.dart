import 'package:webspace/settings/user_script.dart';

/// What a userscript's `// ==UserScript==` header says, as WebSpace acts on
/// it (US-008). Read from the script's full source each time the script is
/// built, never stored: the header text is the one owner of what it means.
typedef UserscriptHeader = ({
  /// The first `@name`, null when the header names none.
  String? name,

  /// The pages the script runs on (US-009).
  Pages include,

  /// The pages it never runs on, whatever [include] says.
  List<UrlPattern> exclude,

  /// The injection time `@run-at` sets, null when it sets none (US-010).
  UserScriptInjectionTime? runAt,

  /// The keys the header asks for that WebSpace does not provide (US-012).
  List<HeaderEntry> notProvided,

  /// What the editor reports about the header.
  List<HeaderProblem> problems,
});

/// One `// @key value` line of a header.
typedef HeaderEntry = ({String key, String value});

/// [entry] as the header wrote it, for the editor to show.
String headerLine(HeaderEntry entry) =>
    entry.value.isEmpty ? '@${entry.key}' : '@${entry.key} ${entry.value}';

/// An anchored regular expression the page tests a URL with, its flags, and
/// the header value it was compiled from, which the editor shows.
typedef UrlPattern = ({String source, String flags, String written});

typedef _Compiled = ({String source, String flags});

/// Which pages a script runs on.
sealed class Pages {
  const Pages();
}

/// The header names no `@match` or `@include`: every page of the site.
final class EveryPage extends Pages {
  const EveryPage();
}

/// The pages the header's `@match` and `@include` lines name; none when
/// every one of them was invalid.
final class NamedPages extends Pages {
  const NamedPages(this.patterns);

  final List<UrlPattern> patterns;
}

/// Something the editor reports about a header.
sealed class HeaderProblem {
  const HeaderProblem();
}

/// `// ==UserScript==` with no closing line: the block counts as no header.
final class HeaderUnclosed extends HeaderProblem {
  const HeaderUnclosed();
}

/// A `@match`, `@exclude-match`, `@include` or `@exclude` that names no page.
final class InvalidPattern extends HeaderProblem {
  const InvalidPattern(this.entry);

  final HeaderEntry entry;
}

/// A `@run-at` value that is none of the four WebSpace reads.
final class UnknownRunAt extends HeaderProblem {
  const UnknownRunAt(this.value);

  final String value;
}

/// The header of a script with none: it runs on every page at its stored time.
const UserscriptHeader noHeader = (
  name: null,
  include: EveryPage(),
  exclude: [],
  runAt: null,
  notProvided: [],
  problems: [],
);

final _open = RegExp(r'^[ \t]*//[ \t]*==UserScript==[ \t]*$');
final _close = RegExp(r'^[ \t]*//[ \t]*==/UserScript==[ \t]*$');
final _entry = RegExp(r'^[ \t]*//[ \t]*@(\S+)(?:[ \t]+(.*?))?[ \t]*$');

/// The header of [fullSource], the fetched library followed by the user's
/// own code: its first `// ==UserScript==` block, so a library's header wins
/// over one in the code that calls it. Any text reads as some header, or as
/// none; nothing here throws.
UserscriptHeader parseUserscriptHeader(String fullSource) {
  final entries = <HeaderEntry>[];
  var inside = false;
  var closed = false;
  for (final line in fullSource.split(RegExp(r'\r\n|\r|\n'))) {
    if (!inside) {
      inside = _open.hasMatch(line);
      continue;
    }
    if (_close.hasMatch(line)) {
      closed = true;
      break;
    }
    if (_entry.firstMatch(line) case final m?) {
      entries.add((key: m.group(1)!, value: m.group(2) ?? ''));
    }
  }
  if (!inside) return noHeader;
  if (!closed) {
    return (
      name: null,
      include: const EveryPage(),
      exclude: const [],
      runAt: null,
      notProvided: const [],
      problems: const [HeaderUnclosed()],
    );
  }
  return _read(entries);
}

UserscriptHeader _read(List<HeaderEntry> entries) {
  String? name;
  List<UrlPattern>? include;
  final exclude = <UrlPattern>[];
  UserScriptInjectionTime? runAt;
  var runAtSeen = false;
  final notProvided = <HeaderEntry>[];
  final problems = <HeaderProblem>[];
  for (final entry in entries) {
    switch (entry.key) {
      case 'name':
        name ??= entry.value.isEmpty ? null : entry.value;
      case 'match' || 'include':
        include ??= [];
        switch (compileUserscriptMatch(entry)) {
          case final UrlPattern pattern:
            include.add(pattern);
          case null:
            problems.add(InvalidPattern(entry));
        }
      case 'exclude-match' || 'exclude':
        switch (compileUserscriptMatch(entry)) {
          case final UrlPattern pattern:
            exclude.add(pattern);
          case null:
            problems.add(InvalidPattern(entry));
        }
      case 'run-at':
        if (runAtSeen) continue;
        runAtSeen = true;
        runAt = switch (entry.value) {
          'document-start' => UserScriptInjectionTime.atDocumentStart,
          'document-end' ||
          'document-idle' ||
          'document-body' => UserScriptInjectionTime.atDocumentEnd,
          _ => null,
        };
        if (runAt == null) problems.add(UnknownRunAt(entry.value));
      case 'grant':
        if (entry.value != 'none') notProvided.add(entry);
      case 'require' ||
          'resource' ||
          'connect' ||
          'updateURL' ||
          'downloadURL':
        notProvided.add(entry);
    }
  }
  return (
    name: name,
    include: include == null ? const EveryPage() : NamedPages(include),
    exclude: exclude,
    runAt: runAt,
    notProvided: notProvided,
    problems: problems,
  );
}

/// The pattern a `@match`, `@exclude-match`, `@include` or `@exclude` line
/// names, or null when it names no page (US-009).
///
/// A match pattern follows Chrome's grammar: a scheme of `*` is http or
/// https, a host of `*.example.com` is the host and its subdomains on a dot
/// boundary, any port is taken, and the path is a `*` glob over the rest of
/// the URL. An include is a `*` glob over the whole URL, or a `/regex/flags`
/// the page's engine reads as the user wrote it.
UrlPattern? compileUserscriptMatch(HeaderEntry entry) {
  final _Compiled? compiled = switch (entry.key) {
    'match' || 'exclude-match' => _matchPattern(entry.value),
    'include' || 'exclude' => _includePattern(entry.value),
    _ => null,
  };
  if (compiled == null) return null;
  return (source: compiled.source, flags: compiled.flags, written: entry.value);
}

final _matchShape = RegExp(r'^(\*|https?|wss?|ftp|file)://([^/]*)(/.*)$');
final _userRegex = RegExp(r'^/(.+)/([a-z]*)$');

_Compiled? _matchPattern(String value) {
  if (value == '<all_urls>') {
    return (source: r'^(?:https?|wss?|ftp|file)://.*$', flags: '');
  }
  final m = _matchShape.firstMatch(value);
  if (m == null) return null;
  final scheme = m.group(1)!;
  final host = m.group(2)!;
  final path = m.group(3)!;
  final String hostSource;
  if (scheme == 'file') {
    if (host.isNotEmpty) return null;
    hostSource = '';
  } else if (host == '*') {
    hostSource = r'[^/?#:]+';
  } else if (host.startsWith('*.')) {
    final rest = host.substring(2);
    if (rest.isEmpty || rest.contains('*')) return null;
    hostSource = '(?:[^/?#:]+\\.)?${_escape(rest)}';
  } else {
    if (host.isEmpty || host.contains('*')) return null;
    hostSource = _escape(host);
  }
  final schemeSource = scheme == '*' ? 'https?' : scheme;
  final port = scheme == 'file' ? '' : r'(?::\d+)?';
  return (
    source: '^$schemeSource://$hostSource$port${_glob(path)}\$',
    flags: '',
  );
}

_Compiled? _includePattern(String value) {
  if (value.isEmpty) return null;
  if (_userRegex.firstMatch(value) case final m?) {
    final flags = m.group(2)!;
    // A stateful flag makes test() answer by where the last one stopped.
    if (flags.contains(RegExp('[^imsu]'))) return null;
    return (source: m.group(1)!, flags: flags);
  }
  return (source: '^${_glob(value)}\$', flags: '');
}

String _glob(String text) => text.split('*').map(_escape).join('.*');

String _escape(String text) =>
    text.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\/]'), (m) => '\\${m[0]}');
