// Extracts the set of plain network-block hosts from ABP filter-list
// text, to seed the sub-resource interceptor's prefilter Bloom filter
// (see DnsBlockService.getMergedBlockBloom).
//
// Why this exists: on iOS/macOS the JS interceptor consults a Bloom
// filter as a "maybe blocked" prefilter and treats a MISS as a hard
// allow — it never round-trips to Dart. Built from DNS domains only,
// that filter never trips for a host blocked solely by an ABP
// `||domain^` rule, so ABP network rules silently never fire there.
// Unioning these hosts into the filter fixes the false-negative.
//
// The filter is only a prefilter: a false positive just costs one Dart
// round-trip to `blockCheck`, which applies the engine's full rule
// semantics (options, `$domain=`, exceptions) authoritatively. So this
// is deliberately permissive — it extracts the host from any anchored
// `||host...` rule, including option-laden ones, and never has to model
// what the rule actually does. The only thing it must not do is invent
// hosts that aren't there (which would waste round-trips) or split a
// host wrong (which would miss the block).

/// Host label terminators in an Adblock Plus `||host...` pattern: the
/// host ends at the separator anchor, a path, a wildcard, an option
/// marker, an alternation, or a port.
const _hostTerminators = {'^', '/', '*', '\$', '|', ':', '?'};

bool _validHostChar(int c) {
  // a-z, 0-9, '.', '-'. Input is lowercased before this check.
  return (c >= 0x61 && c <= 0x7a) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2e ||
      c == 0x2d;
}

/// Parse [filterText] (one or more concatenated filter lists) and return
/// the lowercased registrable hosts named by anchored `||host...` block
/// rules. Exceptions (`@@||...`), cosmetic rules, comments, and any rule
/// without a clean host (regex, path-only, wildcard host) are skipped —
/// those simply don't get prefiltered, the same as before.
Set<String> extractAbpNetworkBlockHosts(String filterText) {
  final hosts = <String>{};
  for (final rawLine in filterText.split('\n')) {
    final line = rawLine.trim();
    if (line.length < 4) continue; // shortest real rule is "||a.b"
    // Comments and metadata.
    final first = line.codeUnitAt(0);
    if (first == 0x21 /* ! */ || first == 0x5b /* [ */) continue;
    // Only domain-anchored rules. `@@||` exceptions fail this check
    // (they start with '@'), so they're excluded for free.
    if (!(first == 0x7c /* | */ && line.codeUnitAt(1) == 0x7c)) continue;
    // Cosmetic rules can also be domain-scoped (`host##.ad`) but never
    // start with `||`, so reaching here we know it's a network rule.
    var i = 2;
    final start = i;
    final lower = line.toLowerCase();
    while (i < lower.length && !_hostTerminators.contains(lower[i])) {
      if (!_validHostChar(lower.codeUnitAt(i))) {
        i = -1;
        break;
      }
      i++;
    }
    if (i < 0) continue; // wildcard or illegal char inside the host
    final host = lower.substring(start, i);
    if (host.length < 3 || !host.contains('.')) continue;
    if (host.startsWith('.') || host.endsWith('.') || host.startsWith('-')) {
      continue;
    }
    hosts.add(host);
  }
  return hosts;
}
