/// Filter-list pre-parser directives (`!#if`, `!#else`, `!#endif`,
/// `!#include`), which adblock-rust does not implement: its parser reads
/// every `!` line as a comment, so without this an `!#include` pulls in
/// nothing and both branches of an `!#if` are compiled. A list written for
/// uBlock Origin resolves the same way here (CB-017).
library;

/// What each `!#if` token tests: the environment name that makes it hold,
/// or null for one that never holds here (another blocker's own build). A
/// `cap_` token not listed is false; any other token not listed leaves its
/// block unknown.
const Map<String, String?> _tokens = {
  'ext_ublock': 'ublock',
  'ext_ubol': 'ubol',
  'ext_devbuild': 'devbuild',
  'env_brave': 'brave',
  'env_chromium': 'chromium',
  'env_edge': 'edge',
  'env_firefox': 'firefox',
  'env_legacy': 'legacy',
  'env_mobile': 'mobile',
  'env_mv3': 'mv3',
  'env_safari': 'safari',
  'cap_html_filtering': 'html_filtering',
  'cap_ipaddress': 'ipaddress',
  'false': null,
  'ext_abp': null,
  'adguard': 'adguard',
  'adguard_app_android': null,
  'adguard_app_cli': null,
  'adguard_app_ios': null,
  'adguard_app_mac': null,
  'adguard_app_windows': null,
  'adguard_ext_android_cb': null,
  'adguard_ext_chromium': 'chromium',
  'adguard_ext_chromium_mv3': 'mv3',
  'adguard_ext_edge': 'edge',
  'adguard_ext_firefox': 'firefox',
  'adguard_ext_opera': 'chromium',
  'adguard_ext_safari': null,
};

/// The environment this app presents to `!#if`. The engine accepts uBO
/// syntax and scriptlets, so `ublock` holds; the rest names the webview
/// engine the rules will run in, not a browser product.
Set<String> preparserEnv({
  required bool android,
  required bool ios,
  required bool macos,
  required bool linux,
}) =>
    {
      'ublock',
      if (android) 'chromium',
      if (ios || macos || linux) 'safari',
      if (android || ios) 'mobile',
    };

/// Whether a token holds in [env], or null for one this table does not
/// know.
bool? _holds(String token, {required Set<String> env}) {
  if (_tokens.containsKey(token)) {
    final name = _tokens[token];
    return name != null && env.contains(name);
  }
  return token.startsWith('cap_') ? false : null;
}

final RegExp _lexeme = RegExp(r'\s*(\(|\)|!|&&|\|\||[A-Za-z0-9_]+)');

/// The value of an `!#if` expression in [env]: tokens joined by `!`, `&&`
/// and `||` (`&&` binding tighter) and grouped by parentheses. Null when
/// it does not parse or names a token [_tokens] does not know, which keeps
/// both branches of its block.
bool? evaluatePreparserExpr(String expr, {required Set<String> env}) {
  final lexemes = <String>[];
  var at = 0;
  while (at < expr.length) {
    final m = _lexeme.matchAsPrefix(expr, at);
    if (m == null) {
      if (expr.substring(at).trim().isEmpty) break;
      return null;
    }
    lexemes.add(m[1]!);
    at = m.end;
  }
  final values = <String, bool>{};
  for (final lexeme in lexemes) {
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(lexeme)) continue;
    final value = _holds(lexeme, env: env);
    if (value == null) return null;
    values[lexeme] = value;
  }
  final parser = _ExprParser(lexemes, values: values);
  final value = parser.or();
  return parser.done ? value : null;
}

/// A recursive descent over an expression's lexemes; each rule returns
/// null on a lexeme it cannot take.
final class _ExprParser {
  _ExprParser(this._lexemes, {required this.values});

  final List<String> _lexemes;
  final Map<String, bool> values;
  var _at = 0;

  bool get done => _at == _lexemes.length;
  String? get _next => done ? null : _lexemes[_at];

  bool? or() {
    var value = and();
    while (value != null && _next == '||') {
      _at++;
      final right = and();
      value = right == null ? null : value || right;
    }
    return value;
  }

  bool? and() {
    var value = not();
    while (value != null && _next == '&&') {
      _at++;
      final right = not();
      value = right == null ? null : value && right;
    }
    return value;
  }

  bool? not() {
    if (_next == '!') {
      _at++;
      final value = not();
      return value == null ? null : !value;
    }
    return term();
  }

  bool? term() {
    final next = _next;
    if (next == '(') {
      _at++;
      final value = or();
      if (_next != ')') return null;
      _at++;
      return value;
    }
    final value = next == null ? null : values[next];
    if (value != null) _at++;
    return value;
  }
}

/// Each line of [content] with its line break, so a list is copied as it
/// came.
Iterable<String> _lines(String content) =>
    RegExp(r'[^\n]*\n|[^\n]+$').allMatches(content).map((m) => m[0]!);

/// The `!#if` blocks open at a line of a list, in [env].
final class _Blocks {
  _Blocks(this.env);

  final Set<String> env;

  /// Each open block's branch: true or false where its expression holds or
  /// fails, null where it is unknown.
  final List<bool?> _open = [];

  static final RegExp _if = RegExp(r'^!#if(?:\s+(.*))?$');

  /// Whether a line outside every directive is compiled: no open block is
  /// on a branch whose expression failed.
  bool get keeps => !_open.contains(false);

  /// Whether [line] is an `!#if`, `!#else` or `!#endif`, which it applies.
  bool take(String line) {
    final text = line.trim();
    final opening = _if.firstMatch(text);
    if (opening != null) {
      final expr = opening[1];
      _open.add(expr == null ? null : evaluatePreparserExpr(expr, env: env));
      return true;
    }
    if (text == '!#else') {
      if (_open.isNotEmpty) {
        final branch = _open.removeLast();
        _open.add(branch == null ? null : !branch);
      }
      return true;
    }
    if (text == '!#endif') {
      if (_open.isNotEmpty) _open.removeLast();
      return true;
    }
    return false;
  }
}

/// [content] with every line under a branch that fails in [env] removed,
/// and the directives themselves. A list with no directive is returned as
/// it is.
String pruneFilterList(String content, {required Set<String> env}) {
  if (!content.contains('!#')) return content;
  final blocks = _Blocks(env);
  final out = StringBuffer();
  for (final line in _lines(content)) {
    if (blocks.take(line)) continue;
    if (blocks.keeps) out.write(line);
  }
  return out.toString();
}

final RegExp _include = RegExp(r'^!#include\s+(\S+)');

/// Whether an `!#include` path could name a file outside the directory of
/// the list that names it: an absolute URL or path, a climb (`..`, also
/// percent-encoded or with backslashes, which a server may decode into
/// one).
bool _leavesDirectory(String path) {
  if (path.contains('..') ||
      path.toLowerCase().contains('%2e') ||
      path.contains(r'\') ||
      path.startsWith('/')) {
    return true;
  }
  final uri = Uri.tryParse(path);
  return uri == null || uri.hasScheme || uri.hasAuthority;
}

/// A sublist that could not be fetched, or one past the count a list may
/// name; the whole list fails with it.
class FilterListIncludeError implements Exception {
  FilterListIncludeError(this.url);

  final String url;

  @override
  String toString() => 'FilterListIncludeError: $url';
}

/// Inlines every `!#include` outside a false `!#if`, recursively, each
/// sublist resolved against the URL of the list that names it. A sublist
/// is fetched at most once. [maxSublists] bounds what one list can make the
/// app download. The directives stay: pruning happens where the engine is
/// built ([pruneFilterList]).
Future<String> expandFilterListIncludes(
  String content, {
  required String url,
  required Set<String> env,
  required Future<String?> Function(String url) fetch,
  int maxSublists = 64,
}) {
  final fetched = <String>{};
  var fetches = 0;

  Future<String> expand(String text, {required Uri base}) async {
    if (!text.contains('!#include')) return text;
    final blocks = _Blocks(env);
    final out = StringBuffer();
    for (final line in _lines(text)) {
      final path =
          blocks.take(line) ? null : _include.firstMatch(line.trim())?[1];
      if (path == null || !blocks.keeps || _leavesDirectory(path)) {
        out.write(line);
        continue;
      }
      final sublist = base.resolve(path).toString();
      if (!fetched.add(sublist)) continue;
      if (++fetches > maxSublists) throw FilterListIncludeError(sublist);
      final body = await fetch(sublist);
      if (body == null) throw FilterListIncludeError(sublist);
      final expanded = await expand(body, base: Uri.parse(sublist));
      out.write(expanded);
      if (expanded.isNotEmpty && !expanded.endsWith('\n')) out.write('\n');
    }
    return out.toString();
  }

  return expand(content, base: Uri.parse(url));
}
