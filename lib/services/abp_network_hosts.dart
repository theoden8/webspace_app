// Parses ABP filter-list text into the data the sub-resource
// interceptor's prefilter Bloom filters need (see
// DnsBlockService.getMergedBlockBloom + the JS interceptor in
// webview.dart). Two products:
//
//   * hosts  — hosts named by anchored `||host^` rules. Unioned into
//     the host Bloom so the interceptor trips for ABP-only hosts.
//   * tokens — for HOSTLESS network rules (path/substring like
//     `/ads/track.js`), a literal token guaranteed present in any URL
//     the rule matches. The host Bloom can't prefilter these (they
//     match on path, not host), so the JS side tokenizes each URL and
//     round-trips to the engine only when a token hits.
//
// Why this is correct (no false negatives): the JS URL tokenizer splits
// on every non-[a-z0-9] character — the FINEST possible split, so never
// coarser than the engine's own tokenizer. We store each rule's LONGEST
// literal alnum run (>=3). If a rule matches a URL, the rule's literal
// text appears in the URL, so that run appears among the URL's tokens
// and the bloom hits -> we round-trip and the engine decides. Rules we
// can't extract a guaranteed token from (regex, or only sub-3-char
// runs) set [hasUntokenizable]; the engine checks those against every
// request, so the JS side must round-trip on every host-Bloom miss when
// the flag is set.
//
// The token Bloom is only a prefilter: a false positive costs one Dart
// round-trip to blockCheck, which applies the engine's full semantics.

typedef AbpNetworkPrefilter = ({
  Set<String> hosts,
  Set<String> tokens,
  bool hasUntokenizable,
});

/// Host label terminators in an `||host...` pattern: the host ends at
/// the separator anchor, a path, a wildcard, an option marker, an
/// alternation, or a port.
const _hostTerminators = {'^', '/', '*', '\$', '|', ':', '?'};

bool _validHostChar(int c) =>
    (c >= 0x61 && c <= 0x7a) || // a-z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c == 0x2e || // .
    c == 0x2d; //  -

bool _isCosmetic(String line) =>
    line.contains('##') ||
    line.contains('#@#') ||
    line.contains('#?#') ||
    line.contains('#\$#') ||
    line.contains('#%#');

/// Host of an anchored `||host...` rule (line already known to start
/// with `||`), or null if there's no clean host (wildcard, illegal
/// char, empty).
String? _hostAnchoredHost(String line) {
  final lower = line.toLowerCase();
  var i = 2;
  final start = i;
  while (i < lower.length && !_hostTerminators.contains(lower[i])) {
    if (!_validHostChar(lower.codeUnitAt(i))) return null;
    i++;
  }
  final host = lower.substring(start, i);
  if (host.length < 3 || !host.contains('.')) return null;
  if (host.startsWith('.') || host.endsWith('.') || host.startsWith('-')) {
    return null;
  }
  return host;
}

/// Longest run of [a-z0-9] of length >= 3 in [s] (already lowercased),
/// or null if none. Ties keep the first — irrelevant for correctness,
/// since any literal run of the rule is present in a matching URL.
String? _longestAlnumToken(String s) {
  var bestStart = -1, bestLen = 0;
  var start = -1;
  for (var i = 0; i <= s.length; i++) {
    final c = i < s.length ? s.codeUnitAt(i) : 0;
    final alnum = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);
    if (alnum) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      if (i - start > bestLen) {
        bestLen = i - start;
        bestStart = start;
      }
      start = -1;
    }
  }
  if (bestLen < 3) return null;
  return s.substring(bestStart, bestStart + bestLen);
}

/// Single pass over [filterText] producing the interceptor prefilter
/// inputs. See the file header for the correctness argument.
AbpNetworkPrefilter parseAbpNetworkPrefilter(String filterText) {
  final hosts = <String>{};
  final tokens = <String>{};
  var hasUntokenizable = false;
  for (final rawLine in filterText.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final c0 = line.codeUnitAt(0);
    if (c0 == 0x21 /* ! */ || c0 == 0x5b /* [ */) continue; // comment/meta
    if (line.startsWith('@@')) continue; // exception, not a block rule
    if (_isCosmetic(line)) continue;
    // Anchored `||host...` block rule: the host Bloom covers it.
    if (c0 == 0x7c && line.length > 2 && line.codeUnitAt(1) == 0x7c) {
      final h = _hostAnchoredHost(line);
      if (h != null) hosts.add(h);
      continue;
    }
    // Hostless network rule (substring / path / |scheme / regex).
    var pattern = line;
    // Regex rule `/.../` — no guaranteed literal token to extract.
    if (pattern.length > 2 &&
        pattern.codeUnitAt(0) == 0x2f &&
        pattern.codeUnitAt(pattern.length - 1) == 0x2f) {
      hasUntokenizable = true;
      continue;
    }
    final dollar = pattern.indexOf('\$'); // strip options
    if (dollar >= 0) pattern = pattern.substring(0, dollar);
    final tok = _longestAlnumToken(pattern.toLowerCase());
    if (tok != null) {
      tokens.add(tok);
    } else {
      // Only short/empty runs: the engine checks this broadly, so we
      // must round-trip on every host-Bloom miss.
      hasUntokenizable = true;
    }
  }
  return (hosts: hosts, tokens: tokens, hasUntokenizable: hasUntokenizable);
}

/// Hosts named by anchored `||host^` network-block rules. Thin wrapper
/// over [parseAbpNetworkPrefilter] for callers that only need hosts.
Set<String> extractAbpNetworkBlockHosts(String filterText) =>
    parseAbpNetworkPrefilter(filterText).hosts;
