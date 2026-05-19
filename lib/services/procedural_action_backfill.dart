// Bypass for adblock-rust 0.12's parse-time rejection of generic
// procedural rules (cosmetic.rs:444 — `if sharp_index == 0 &&
// action.is_some() { return Err(GenericAction) }`).
//
// Generic rules like `##.foo:remove()`, `##.bar:style(...)`,
// `##.qux:has-text(X):remove()` are rejected at parse time by the
// crate — they never enter the cache, so no FFI surfaces them. The
// crate's own design intentionally drops them. css-validation does
// not change this; the rejection runs before validation.
//
// Workaround: at filter-list ingest time, rewrite any such generic
// rule to have a sentinel synthetic hostname (`localhost`). The
// parser now sees `localhost##.foo:remove()`, which has a hostname
// so it bypasses the GenericAction check, and stores the rule as a
// domain-scoped procedural. At query time we additionally call
// `cosmeticResources('https://localhost/')` and union the
// procedural_actions in with whatever the real URL returned.
//
// `localhost` is the natural choice: it's the host the rendered
// page actually uses in local-test workflows (the probe page hosted
// via `python3 -m http.server`), so backfilled procedurals fire
// "for free" on those without us having to wire a second query.
// Trade-off: pre-existing filter rules targeting localhost mix with
// our backfilled set — fine in practice since localhost-anchored
// rules are vanishingly rare in real filter lists.
//
// Why this beats an in-Dart parser: we re-use the crate's full
// parsing and selector/action extraction (correctness > our own
// regex). The only Dart-side work is the prefix rewrite.

const String kBackfillSyntheticHost = 'localhost';

/// Trailing procedural action pseudos: `:remove()` /
/// `:remove-attr(...)` / `:remove-class(...)` / `:style(...)`. When
/// present, the rewriter just prepends the synthetic host and is done.
final RegExp _actionPseudo = RegExp(
  r':(?:remove\(\)|remove-attr\([^)]*\)|remove-class\([^)]*\)|style\([^)]*\))\s*$',
);

/// Procedural FILTER pseudos that produce default-hide rules in uBO
/// syntax: `:has-text(...)`, `:contains(...)`, `:-abp-contains(...)`,
/// `:-abp-has(...)`, `:upward(...)`. Standard CSS `:has(` is NOT
/// included — the engine + browser handle that natively.
///
/// When one of these appears without an explicit action pseudo, the
/// rule means "hide elements matching this selector chain"; the
/// crate stores the rule as a hide selector with the procedural
/// pseudo embedded in the selector string, but the early-CSS
/// injection then can't match anything because the pseudo isn't real
/// CSS. The rewriter converts these into procedural rules with an
/// explicit `:style(display: none !important)` action so they ride
/// the procedural shim runner instead.
final RegExp _filterPseudo = RegExp(
  r':(?:has-text|contains|-abp-contains|-abp-has|upward)\(',
);

/// adblock-rust's css-validation pass only accepts the canonical uBO
/// pseudo names (`:has-text(`, native `:has(`). ABP-syntax aliases
/// (`:-abp-contains(`, `:contains(`, `:-abp-has(`) are silently
/// rejected as invalid CSS and the whole rule is dropped. Map them
/// to the canonical forms before handing the rule to the parser.
///
/// Order matters: `:-abp-contains` must be checked BEFORE `:contains`
/// so the longer prefix wins.
String _normalizeAbpAliases(String line) {
  return line
      .replaceAll(':-abp-contains(', ':has-text(')
      .replaceAll(':contains(', ':has-text(')
      .replaceAll(':-abp-has(', ':has(');
}

const String _syntheticHideAction = ':style(display: none !important)';

/// Rewrite filter-list text so generic cosmetic rules that carry
/// procedural operators (action pseudo OR filter pseudo) gain a
/// synthetic hostname prefix. Filter-pseudo-only rules additionally
/// get a synthetic `:style(display:none !important)` action so they
/// flow through the procedural shim runner.
///
/// Idempotent on already-rewritten input.
String rewriteGenericProceduralsForBackfill(String rulesText) {
  final out = StringBuffer();
  var rewriteCount = 0;
  for (final rawLine in rulesText.split('\n')) {
    final classification = _classify(rawLine);
    switch (classification) {
      case _RewriteKind.none:
        out.write(rawLine);
      case _RewriteKind.action:
        out.write(kBackfillSyntheticHost);
        out.write(_normalizeAbpAliases(rawLine));
        rewriteCount++;
      case _RewriteKind.filterOnly:
        out.write(kBackfillSyntheticHost);
        out.write(_normalizeAbpAliases(rawLine));
        out.write(_syntheticHideAction);
        rewriteCount++;
    }
    out.write('\n');
  }
  // Trim the trailing newline we'd otherwise add for the (empty)
  // line after the last real line; keep matching the input shape.
  final result = out.toString();
  return rewriteCount == 0
      ? rulesText
      : (rulesText.endsWith('\n') ? result : result.substring(0, result.length - 1));
}

enum _RewriteKind { none, action, filterOnly }

_RewriteKind _classify(String line) {
  if (line.isEmpty) return _RewriteKind.none;
  if (line.startsWith('!') || line.startsWith('[')) return _RewriteKind.none;
  // Cosmetic marker: rule must start with `##` (generic hide) or
  // `#?#` (uBO procedural variant). Domain-scoped rules
  // (`example.com##...`) don't start with `#` so they fall through.
  final start = line.startsWith('##')
      ? 2
      : line.startsWith('#?#')
          ? 3
          : -1;
  if (start < 0) return _RewriteKind.none;
  // +js(...) scriptlet injection isn't a cosmetic rule — leave alone.
  if (line.substring(start).trimLeft().startsWith('+js(')) return _RewriteKind.none;
  if (_actionPseudo.hasMatch(line)) return _RewriteKind.action;
  if (_filterPseudo.hasMatch(line)) return _RewriteKind.filterOnly;
  return _RewriteKind.none;
}
