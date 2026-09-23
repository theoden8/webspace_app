/// uBlock Origin's filter-list pre-parser directives, which adblock-rust
/// does not implement: its parser reads every `!` line as a comment, so
/// without this an `!#include` pulls in nothing and both branches of an
/// `!#if` are compiled.
///
/// Ported from uBO's `utils.preparser` (`static-filtering-parser.js`) and
/// `assets.fetchFilterList` (`assets.js`); the token table, the expression
/// grammar and the include restrictions match uBO so a list written for it
/// resolves the same way here.
library;

/// uBO's token table: directive token -> the environment name it tests.
/// `'false'` means the token never holds.
const Map<String, String> _kTokens = {
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
  'false': 'false',
  'ext_abp': 'false',
  'adguard': 'adguard',
  'adguard_app_android': 'false',
  'adguard_app_cli': 'false',
  'adguard_app_ios': 'false',
  'adguard_app_mac': 'false',
  'adguard_app_windows': 'false',
  'adguard_ext_android_cb': 'false',
  'adguard_ext_chromium': 'chromium',
  'adguard_ext_chromium_mv3': 'mv3',
  'adguard_ext_edge': 'edge',
  'adguard_ext_firefox': 'firefox',
  'adguard_ext_opera': 'chromium',
  'adguard_ext_safari': 'false',
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

/// Evaluates one `!#if` expression. Null means uBO would not recognise it,
/// in which case the block is kept, as uBO keeps it.
bool? evaluatePreparserExpr(String expr, Set<String> env) {
  var e = expr.trim();
  if (e.startsWith('(') && e.endsWith(')')) e = e.substring(1, e.length - 1);
  final matches =
      RegExp(r'(?:(?:&&|\|\|)\s+)?\S+').allMatches(e).map((m) => m[0]!).toList();
  if (matches.isEmpty) return null;
  if (matches.first.startsWith('|') || matches.first.startsWith('&')) {
    return null;
  }
  var result = _evaluateToken(matches.first, env);
  for (var i = 1; i < matches.length; i++) {
    final parts = matches[i].split(RegExp(r' +'));
    if (parts.length != 2) return null;
    final state = _evaluateToken(parts[1], env);
    if (state == null) return null;
    // JS semantics of uBO's `result || state` / `result && state` with an
    // undefined first operand.
    if (parts[0] == '||') {
      result = (result ?? false) || state;
    } else if (parts[0] == '&&') {
      result = result == null ? null : result && state;
    } else {
      return null;
    }
  }
  return result;
}

bool? _evaluateToken(String token, Set<String> env) {
  final not = token.startsWith('!');
  if (not) token = token.substring(1);
  var state = _kTokens[token];
  if (state == null) {
    if (!token.startsWith('cap_')) return null;
    state = 'false';
  }
  return (state == 'false' && not) || (env.contains(state) != not);
}

class _IfFrame {
  bool known;
  bool discard;
  int pos;
  _IfFrame(this.known, this.discard, this.pos);
}

/// Offsets that alternately start a kept and a discarded span, beginning
/// with a kept span at 0 and ending at `content.length`. Same contract as
/// uBO's `splitter`.
List<int> _splitter(String content, Set<String> env) {
  final reIf = RegExp(r'^!#(if|else|endif)\b([^\n]*)(?:[\n\r]+|$)',
      multiLine: true);
  final stack = <_IfFrame>[];
  final parts = <int>[0];
  var discard = false;

  bool shouldDiscard() => stack.any((f) => f.known && f.discard);

  void begif(_IfFrame f) {
    if (!discard && f.known && f.discard) {
      parts.add(f.pos);
      discard = true;
    }
    stack.add(f);
  }

  void endif(Match m) {
    if (stack.isNotEmpty) stack.removeLast();
    if (discard && !shouldDiscard()) {
      parts.add(m.end);
      discard = false;
    }
  }

  for (final m in reIf.allMatches(content)) {
    switch (m[1]) {
      case 'if':
        final result = evaluatePreparserExpr(m[2]!.trim(), env);
        begif(_IfFrame(result != null, result == false, m.start));
      case 'else':
        if (stack.isEmpty) break;
        final f = stack.last;
        endif(m);
        f.discard = !f.discard;
        f.pos = m.start;
        begif(f);
      case 'endif':
        endif(m);
    }
  }
  parts.add(content.length);
  return parts;
}

/// Drops the spans a false `!#if` excludes.
String pruneFilterList(String content, Set<String> env) {
  if (!content.contains('!#')) return content;
  final parts = _splitter(content, env);
  final out = StringBuffer();
  for (var i = 0; i + 1 < parts.length; i += 2) {
    if (i > 0) out.write('\n');
    out.write(content.substring(parts[i], parts[i + 1]));
  }
  return out.toString();
}

/// An `!#include` that uBO would refuse: an absolute URL, or a path that
/// climbs out of the parent list's directory. The percent-encoded dot is
/// refused too, since a server may decode it into `..`.
bool _refusedIncludePath(String path) {
  if (Uri.tryParse(path)?.hasScheme ?? false) return true;
  if (path.contains('..')) return true;
  if (path.toLowerCase().contains('%2e')) return true;
  if (path.contains('\\')) return true;
  return false;
}

/// Thrown when an included sublist cannot be fetched. uBO fails the whole
/// list in that case rather than compiling a partial one.
class FilterListIncludeError implements Exception {
  final String url;
  FilterListIncludeError(this.url);
  @override
  String toString() => 'FilterListIncludeError: $url';
}

/// Inlines every `!#include` outside a false `!#if`, recursively, each
/// sublist resolved against the URL of the list that names it. A sublist
/// is fetched at most once. [maxSublists] bounds what one list can make the
/// app download.
Future<String> expandFilterListIncludes(
  String content,
  String url,
  Set<String> env,
  Future<String?> Function(String url) fetch, {
  int maxSublists = 64,
}) async {
  final seen = <String>{};

  Future<String> expand(String text, String parentUrl) async {
    if (!text.contains('!#include')) return text;
    final slash = parentUrl.lastIndexOf('/');
    if (slash < 0) return text;
    final base = parentUrl.substring(0, slash + 1);
    final reInclude =
        RegExp(r'^!#include +(\S+)[^\n\r]*(?:[\n\r]+|$)', multiLine: true);
    final parts = _splitter(text, env);
    final out = StringBuffer();
    for (var i = 0; i + 1 < parts.length; i++) {
      final slice = text.substring(parts[i], parts[i + 1]);
      if (i.isOdd) {
        out.write(slice);
        continue;
      }
      var last = 0;
      for (final m in reInclude.allMatches(slice)) {
        final path = m[1]!.trim();
        if (_refusedIncludePath(path)) continue;
        final subUrl = base + path;
        if (!seen.add(subUrl)) continue;
        if (seen.length > maxSublists) throw FilterListIncludeError(subUrl);
        final body = await fetch(subUrl);
        if (body == null) throw FilterListIncludeError(subUrl);
        out
          ..write(slice.substring(last, m.end))
          ..write('! >>>>>>>> $subUrl\n')
          ..write(await expand('${body.trimRight()}\n', subUrl))
          ..write('! <<<<<<<< $subUrl\n');
        last = m.end;
      }
      out.write(last == 0 ? slice : slice.substring(last));
    }
    return out.toString();
  }

  return expand(content, url);
}
