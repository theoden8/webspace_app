/// Resolves a filter list's pre-parser directives (CB-017) before the list
/// reaches adblock-rust, which reads every `!` line as a comment:
/// `!#include` when the list is downloaded ([expandFilterListIncludes]),
/// `!#if` / `!#else` / `!#endif` when the engine is built
/// ([pruneFilterList]), so a list is stored whole and the environment is
/// applied where it runs.
library;

/// The traits of the engine the rules run in, as `!#if` tokens test them:
/// `ublock` always, since the engine takes uBO syntax and scriptlets;
/// `chromium` on Android; `safari` on the WebKit hosts; `mobile` on Android
/// and iOS.
Set<String> preparserEnv({
  required bool android,
  required bool ios,
  required bool macos,
  required bool linux,
}) => Set.unmodifiable({
  'ublock',
  if (android) 'chromium',
  if (ios || macos || linux) 'safari',
  if (android || ios) 'mobile',
});

/// Whether an `!#if` expression holds in [env], or null when it does not
/// parse or names a token neither [_tokenNeeds] nor [_neverHolds] knows, so
/// the block keeps both branches. An unknown `cap_` token is false.
bool? evaluatePreparserExpr(String expr, {required Set<String> env}) {
  final tokens = _tokensOf(expr);
  if (tokens == null || tokens.length > _maxExprTokens) return null;
  return _ExprParser(tokens, env: env).whole();
}

/// [content] without the lines under a branch that is false in [env], and
/// without its directive lines; [content] itself when it has no directive.
String pruneFilterList(String content, {required Set<String> env}) {
  final blocks = _Blocks(env: env);
  final out = StringBuffer();
  var resolved = false;
  for (final line in _lines(content)) {
    switch (_directiveOf(line)) {
      case null:
        if (blocks.live) out.write(line);
      case final _Conditional directive:
        resolved = true;
        blocks.take(directive);
      case _Include():
        resolved = true;
    }
  }
  return resolved ? out.toString() : content;
}

/// [content], the list downloaded from [url], with each `!#include` under a
/// branch that is not false in [env] replaced by the sublist it names,
/// expanded the same way. A path that could leave the directory of the list
/// naming it is dropped unfetched, and a sublist already fetched is not
/// fetched again.
///
/// Throws [FilterListIncludeError] for a sublist [fetch] returns null for,
/// or for one past [maxSublists] fetches.
Future<String> expandFilterListIncludes(
  String content, {
  required String url,
  required Set<String> env,
  required Future<String?> Function(String url) fetch,
  int maxSublists = 64,
}) {
  final top = Uri.parse(url);
  return _Expansion(
    env: env,
    fetch: fetch,
    maxSublists: maxSublists,
    top: top,
  ).expand(content, base: top);
}

/// A sublist that could not be fetched, or one past the bound, which fails
/// the whole download that named it.
class FilterListIncludeError implements Exception {
  FilterListIncludeError(this.url);

  final String url;

  @override
  String toString() => 'FilterListIncludeError: $url';
}

/// The `!#if` tokens that hold when the environment names the trait each
/// maps to.
const Map<String, String> _tokenNeeds = {
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
  'adguard': 'adguard',
  'adguard_ext_chromium': 'chromium',
  'adguard_ext_chromium_mv3': 'mv3',
  'adguard_ext_edge': 'edge',
  'adguard_ext_firefox': 'firefox',
  'adguard_ext_opera': 'chromium',
};

/// The `!#if` tokens that never hold here: other blockers and their builds.
const Set<String> _neverHolds = {
  'false',
  'ext_abp',
  'adguard_app_android',
  'adguard_app_cli',
  'adguard_app_ios',
  'adguard_app_mac',
  'adguard_app_windows',
  'adguard_ext_android_cb',
  'adguard_ext_safari',
};

/// Whether [token] holds in [env]; null for a token neither table knows,
/// except that a capability nobody declared is absent.
bool? _tokenHolds(String token, {required Set<String> env}) {
  if (_neverHolds.contains(token)) return false;
  final trait = _tokenNeeds[token];
  if (trait != null) return env.contains(trait);
  return token.startsWith('cap_') ? false : null;
}

/// The longest expression taken, so a hostile list cannot nest one deep
/// enough to exhaust the parser's stack; a longer one is taken as unparsed.
const int _maxExprTokens = 256;

const Set<String> _operators = {'!', '&&', '||', '(', ')'};

final RegExp _exprToken = RegExp(r'\s*(&&|\|\||[!()]|\w+)');

/// [expr] as operators and tokens, or null where it holds anything else.
List<String>? _tokensOf(String expr) {
  final tokens = <String>[];
  var at = 0;
  for (
    var match = _exprToken.matchAsPrefix(expr);
    match != null;
    match = _exprToken.matchAsPrefix(expr, match.end)
  ) {
    tokens.add(match[1]!);
    at = match.end;
  }
  return expr.substring(at).trim().isEmpty ? tokens : null;
}

/// A recursive descent over one expression: `||` over `&&` over `!` over a
/// token or a parenthesized expression. Null, for an expression that does
/// not parse or a token that is not known, ends the descent and is the
/// answer.
final class _ExprParser {
  _ExprParser(this._tokens, {required this.env});

  final List<String> _tokens;
  final Set<String> env;
  var _at = 0;

  bool? whole() {
    final value = _or();
    return _at == _tokens.length ? value : null;
  }

  bool? _or() {
    var value = _and();
    while (value != null && _take('||')) {
      final right = _and();
      value = right == null ? null : value || right;
    }
    return value;
  }

  bool? _and() {
    var value = _operand();
    while (value != null && _take('&&')) {
      final right = _operand();
      value = right == null ? null : value && right;
    }
    return value;
  }

  bool? _operand() {
    if (_take('!')) {
      final value = _operand();
      return value == null ? null : !value;
    }
    if (_take('(')) {
      final value = _or();
      return _take(')') ? value : null;
    }
    if (_at == _tokens.length || _operators.contains(_tokens[_at])) {
      return null;
    }
    return _tokenHolds(_tokens[_at++], env: env);
  }

  bool _take(String operator) {
    if (_at == _tokens.length || _tokens[_at] != operator) return false;
    _at++;
    return true;
  }
}

/// A directive line of a filter list.
sealed class _Directive {
  const _Directive();
}

final class _Include extends _Directive {
  const _Include(this.path);

  final String path;
}

/// A directive that opens, turns or closes an `!#if` block.
sealed class _Conditional extends _Directive {
  const _Conditional();
}

final class _If extends _Conditional {
  const _If(this.expr);

  final String expr;
}

final class _Else extends _Conditional {
  const _Else();
}

final class _EndIf extends _Conditional {
  const _EndIf();
}

final RegExp _directive = RegExp(r'^!#(if|else|endif|include)\b\s*(.*)$');

/// The directive [line] carries, or null for any other line.
_Directive? _directiveOf(String line) {
  if (!line.contains('!#')) return null;
  final match = _directive.firstMatch(line.trim());
  if (match == null) return null;
  final argument = match[2]!;
  return switch (match[1]!) {
    'if' => _If(argument),
    'else' => const _Else(),
    'endif' => const _EndIf(),
    _ => _Include(argument),
  };
}

/// The `!#if` blocks open at a line of one list, innermost last, each as the
/// value of the branch the line is in: null where the expression is unknown
/// and both branches stay.
final class _Blocks {
  _Blocks({required this.env});

  final Set<String> env;
  final List<bool?> _open = [];

  /// Whether the line is in no false branch.
  bool get live => !_open.contains(false);

  int get depth => _open.length;

  /// Applies [directive]; false for an `!#else` or `!#endif` that closes no
  /// block, which changes nothing.
  bool take(_Conditional directive) {
    switch (directive) {
      case _If(:final expr):
        _open.add(evaluatePreparserExpr(expr, env: env));
        return true;
      case _Else():
        if (_open.isEmpty) return false;
        final holds = _open.last;
        _open.last = holds == null ? null : !holds;
        return true;
      case _EndIf():
        if (_open.isEmpty) return false;
        _open.removeLast();
        return true;
    }
  }
}

/// [content]'s lines, each with the line break it came with.
Iterable<String> _lines(String content) sync* {
  var start = 0;
  while (start < content.length) {
    final end = content.indexOf('\n', start);
    final next = end < 0 ? content.length : end + 1;
    yield content.substring(start, next);
    start = next;
  }
}

String _lineBreakOf(String line) => line.endsWith('\r\n')
    ? '\r\n'
    : line.endsWith('\n')
    ? '\n'
    : '';

/// The sublist an `!#include` path names in the directory of the list at
/// [base], or null for a path that could leave it: an absolute URL, one from
/// the host's root, a climb, or what a server may decode into one.
Uri? _sublistUrl(String path, {required Uri base}) {
  if (path.startsWith('/') ||
      path.contains('..') ||
      path.contains(r'\') ||
      path.toLowerCase().contains('%2e')) {
    return null;
  }
  final relative = Uri.tryParse(path);
  if (relative == null || relative.hasScheme || relative.path.isEmpty) {
    return null;
  }
  final url = base.resolveUri(relative);
  assert(
    url.toString().startsWith(base.resolve('.').toString()),
    'a refused path is the only way out of the directory',
  );
  return url;
}

/// One download's expansion: the sublists it has fetched, shared by every
/// list it reaches, so each is fetched once and their count is bounded.
///
/// An expanded list's `!#if` blocks are closed at its end and its unmatched
/// `!#else` and `!#endif` dropped, so a sublist's blocks end where it ends,
/// as they did when its own includes were decided.
final class _Expansion {
  _Expansion({
    required this.env,
    required this.fetch,
    required this.maxSublists,
    required Uri top,
  }) : _seen = {top.toString()};

  final Set<String> env;
  final Future<String?> Function(String url) fetch;
  final int maxSublists;
  final Set<String> _seen;
  var _fetched = 0;

  Future<String> expand(String content, {required Uri base}) async {
    final blocks = _Blocks(env: env);
    final out = StringBuffer();
    for (final line in _lines(content)) {
      switch (_directiveOf(line)) {
        case null:
          out.write(line);
        case final _Conditional directive:
          if (blocks.take(directive)) out.write(line);
        case _Include(:final path):
          final url = blocks.live ? _sublistUrl(path, base: base) : null;
          if (url != null && _seen.add(url.toString())) {
            final sublist = await _sublist(url);
            out.write(sublist);
            if (sublist.isNotEmpty && !sublist.endsWith('\n')) {
              out.write(_lineBreakOf(line));
            }
          }
      }
    }
    final text = out.toString();
    if (blocks.depth == 0) return text;
    final lineBreak = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    return '$text$lineBreak${'!#endif\n' * blocks.depth}';
  }

  Future<String> _sublist(Uri url) async {
    if (_fetched >= maxSublists) throw FilterListIncludeError(url.toString());
    _fetched++;
    final body = await fetch(url.toString());
    if (body == null) throw FilterListIncludeError(url.toString());
    return expand(body, base: url);
  }
}
