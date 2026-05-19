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

/// Regex matching the trailing procedural action pseudo on a cosmetic
/// rule: `:remove()`, `:remove-attr(...)`, `:remove-class(...)`, or
/// `:style(...)`. Anchored to end-of-line to avoid false hits where
/// `:style(` appears as text inside something else.
final RegExp _actionPseudo = RegExp(
  r':(?:remove\(\)|remove-attr\([^)]*\)|remove-class\([^)]*\)|style\([^)]*\))\s*$',
);

/// Rewrite filter-list text so generic cosmetic rules that carry a
/// procedural action gain a synthetic hostname prefix. Lines that
/// already have a domain prefix, lines that are network/network-
/// exception rules, comments, and lines without an action pseudo
/// pass through unchanged.
///
/// Idempotent on already-rewritten input.
String rewriteGenericProceduralsForBackfill(String rulesText) {
  final out = StringBuffer();
  var rewriteCount = 0;
  for (final rawLine in rulesText.split('\n')) {
    if (_shouldRewrite(rawLine)) {
      out.write(kBackfillSyntheticHost);
      out.write(rawLine);
      rewriteCount++;
    } else {
      out.write(rawLine);
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

bool _shouldRewrite(String line) {
  if (line.isEmpty) return false;
  if (line.startsWith('!') || line.startsWith('[')) return false;
  // Cosmetic marker: rule must start with `##` (generic hide) or
  // `#?#` (uBO procedural variant). Domain-scoped rules
  // (`example.com##...`) don't start with `#` so they fall through.
  final start = line.startsWith('##')
      ? 2
      : line.startsWith('#?#')
          ? 3
          : -1;
  if (start < 0) return false;
  // +js(...) scriptlet injection isn't a cosmetic rule — leave alone.
  if (line.substring(start).trimLeft().startsWith('+js(')) return false;
  return _actionPseudo.hasMatch(line);
}
