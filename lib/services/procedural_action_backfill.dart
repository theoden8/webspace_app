// Dart-side backfill for cosmetic rule shapes adblock-rust 0.12 can
// parse (with css-validation on) but can't surface to consumers via
// the URL-keyed cosmetic_resources path. Two such shapes:
//
//   * `##.foo:has-text(X):remove()` / `:upward()` / `:remove-attr()` /
//     `:remove-class()` — class/id-anchored generic procedurals. The
//     crate stores them but has no public method that returns
//     procedural actions by class/id (parallel to
//     `hidden_class_id_selectors` for hide rules). Tracked upstream
//     as the adblock-rust issue family around #520 / #537 / #609.
//
//   * `##.foo:style(decls)` — generic uBO style overrides. Same
//     storage story; same missing query path.
//
// This file does NOT re-parse anything adblock-rust already returns
// (regular hide selectors, attribute selectors, native :has,
// domain-scoped procedurals, network rules). Strictly the gap-filler
// for the post-65be41b world where the legacy in-Dart ABP parser is
// gone.
//
// Output shape mirrors what `buildProceduralCosmeticShim` already
// consumes — the engine's `procedural_actions` field is a list of
// JSON-encoded action objects — so backfilled rules and engine rules
// flow through the same runner without branching on origin.

import 'dart:convert';

/// Per-anchor buckets of procedural and style rules pulled from the
/// raw filter-list text. `procByClass['foo']` lists JSON-encoded
/// procedural rules anchored on `##.foo:...`; same for ids.
class ProceduralBackfill {
  final Map<String, List<String>> procByClass = {};
  final Map<String, List<String>> procById = {};
  final Map<String, List<String>> styleByClass = {};
  final Map<String, List<String>> styleById = {};
  // Rules with no class/id anchor: pure tag/attr selectors with a
  // trailing procedural action. Always returned regardless of the
  // page-scanned class/id sets.
  final List<String> procAnchorless = [];
  final List<String> styleAnchorless = [];

  bool get isEmpty =>
      procByClass.isEmpty &&
      procById.isEmpty &&
      styleByClass.isEmpty &&
      styleById.isEmpty &&
      procAnchorless.isEmpty &&
      styleAnchorless.isEmpty;

  int get procRuleCount =>
      procAnchorless.length +
      procByClass.values.fold(0, (s, l) => s + l.length) +
      procById.values.fold(0, (s, l) => s + l.length);

  int get styleRuleCount =>
      styleAnchorless.length +
      styleByClass.values.fold(0, (s, l) => s + l.length) +
      styleById.values.fold(0, (s, l) => s + l.length);
}

/// Parse [rulesText] (the same blob fed to adblock-rust) for the
/// procedural + `:style()` shapes the crate's public API drops.
/// Returns an empty [ProceduralBackfill] when nothing matches.
///
/// Host-scoped rules (`example.com##sel:remove()`) are deliberately
/// skipped — `engine.cosmeticResources(url).procedural_actions`
/// already surfaces those for the matching hostname.
ProceduralBackfill parseProceduralBackfill(String rulesText) {
  final out = ProceduralBackfill();
  for (final rawLine in rulesText.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('!') || line.startsWith('[')) continue;
    // Cosmetic marker: `##` or `#?#`. uBO uses `#?#` to flag the
    // procedural variant explicitly; both share the same syntax
    // inside the selector portion so we treat them identically.
    var hashIdx = line.indexOf('##');
    var hashLen = 2;
    if (hashIdx < 0) {
      hashIdx = line.indexOf('#?#');
      hashLen = 3;
    }
    if (hashIdx < 0) continue;
    // Domain prefix on the left → host-scoped, engine handles it.
    if (hashIdx != 0) continue;
    final selector = line.substring(hashLen).trim();
    if (selector.isEmpty) continue;
    if (selector.startsWith('+js(')) continue; // scriptlet injection

    final styled = _extractStyleRule(selector);
    if (styled != null) {
      _bucketStyle(out, styled.selector, styled.declarations);
      continue;
    }
    final proc = _extractProceduralAction(selector);
    if (proc != null) {
      _bucketProcedural(out, proc);
    }
  }
  return out;
}

/// Page-side scan input: classes and ids found on the loaded page.
/// Returns the JSON-encoded procedural + style rules that apply.
({List<String> procedural, List<String> style}) backfilledRulesFor({
  required ProceduralBackfill backfill,
  required Set<String> classes,
  required Set<String> ids,
}) {
  if (backfill.isEmpty) return (procedural: const [], style: const []);
  final proc = <String>[
    ...backfill.procAnchorless,
    for (final c in classes) ...?backfill.procByClass[c],
    for (final i in ids) ...?backfill.procById[i],
  ];
  final style = <String>[
    ...backfill.styleAnchorless,
    for (final c in classes) ...?backfill.styleByClass[c],
    for (final i in ids) ...?backfill.styleById[i],
  ];
  return (procedural: proc, style: style);
}

void _bucketProcedural(
    ProceduralBackfill out, _ProceduralParsed parsed) {
  final encoded = jsonEncode({
    'selector': [
      {'type': 'css-selector', 'arg': parsed.selector},
    ],
    'action': parsed.actionArg.isEmpty
        ? parsed.actionType
        : {'type': parsed.actionType, 'arg': parsed.actionArg},
  });
  final anchor = _anchorFromSelector(parsed.selector);
  if (anchor == null) {
    out.procAnchorless.add(encoded);
  } else if (anchor.isClass) {
    (out.procByClass[anchor.name] ??= []).add(encoded);
  } else {
    (out.procById[anchor.name] ??= []).add(encoded);
  }
}

void _bucketStyle(
    ProceduralBackfill out, String selector, String declarations) {
  final encoded = jsonEncode({
    'selector': [
      {'type': 'css-selector', 'arg': selector},
    ],
    'action': {'type': 'style', 'arg': declarations},
  });
  final anchor = _anchorFromSelector(selector);
  if (anchor == null) {
    out.styleAnchorless.add(encoded);
  } else if (anchor.isClass) {
    (out.styleByClass[anchor.name] ??= []).add(encoded);
  } else {
    (out.styleById[anchor.name] ??= []).add(encoded);
  }
}

class _Anchor {
  final String name;
  final bool isClass; // false → id
  const _Anchor(this.name, this.isClass);
}

/// Pull the first `.class` or `#id` token out of a selector for
/// bucketing. `div.foo.bar:has-text(x)` → class "foo". Returns null
/// for selectors with no class/id anchor (pure attribute / `*` /
/// tag selectors); those become anchorless and always apply.
_Anchor? _anchorFromSelector(String selector) {
  for (var i = 0; i < selector.length; i++) {
    final c = selector[i];
    if (c == ' ' || c == '>' || c == '+' || c == '~' ||
        c == ':' || c == '[') break;
    if (c == '.' || c == '#') {
      final isClass = c == '.';
      final start = i + 1;
      var j = start;
      while (j < selector.length) {
        final ch = selector[j];
        if (ch == '.' || ch == '#' || ch == ' ' || ch == '>' ||
            ch == '+' || ch == '~' || ch == ':' || ch == '[') {
          break;
        }
        j++;
      }
      if (j > start) return _Anchor(selector.substring(start, j), isClass);
    }
  }
  return null;
}

/// Extract `selector` and `declarations` from `<sel>:style(<decls>)`.
/// `:style()` must terminate the rule; embedded `:style()` inside a
/// longer chain isn't a shape uBO emits so we don't handle it.
({String selector, String declarations})? _extractStyleRule(String rule) {
  final styleIdx = rule.indexOf(':style(');
  if (styleIdx < 0) return null;
  final selectorPart = rule.substring(0, styleIdx).trim();
  if (selectorPart.isEmpty) return null;
  final start = styleIdx + ':style('.length;
  var depth = 1;
  var i = start;
  while (i < rule.length && depth > 0) {
    if (rule[i] == '(') depth++;
    if (rule[i] == ')') depth--;
    i++;
  }
  if (depth != 0) return null;
  final declarations = rule.substring(start, i - 1).trim();
  if (declarations.isEmpty) return null;
  if (rule.substring(i).trim().isNotEmpty) return null;
  return (selector: selectorPart, declarations: declarations);
}

class _ProceduralParsed {
  final String selector;
  final String actionType; // remove / remove-attr / remove-class
  final String actionArg;
  const _ProceduralParsed(this.selector, this.actionType, this.actionArg);
}

/// Detect the uBO procedural-action pseudo that terminates a
/// cosmetic selector. Filter pseudos earlier in the selector
/// (`:has-text()`, `:upward()`, `:-abp-contains()`) stay inside the
/// selector string; the page-side shim parses them out at run time
/// before feeding the pure-CSS portion to `querySelectorAll`.
_ProceduralParsed? _extractProceduralAction(String rule) {
  // Order matters: try the longest token first so `:remove-attr(`
  // doesn't accidentally match the `:remove()` branch.
  for (final spec in const [
    (':remove-attr(', 'remove-attr'),
    (':remove-class(', 'remove-class'),
    (':remove()', 'remove'),
  ]) {
    final token = spec.$1;
    final action = spec.$2;
    final idx = rule.indexOf(token);
    if (idx < 0) continue;
    final selectorPart = rule.substring(0, idx).trim();
    if (selectorPart.isEmpty) return null;
    if (action == 'remove') {
      if (rule.substring(idx + token.length).trim().isNotEmpty) return null;
      return _ProceduralParsed(selectorPart, 'remove', '');
    }
    final start = idx + token.length;
    var depth = 1;
    var i = start;
    while (i < rule.length && depth > 0) {
      if (rule[i] == '(') depth++;
      if (rule[i] == ')') depth--;
      i++;
    }
    if (depth != 0) return null;
    final arg = rule.substring(start, i - 1).trim();
    if (arg.isEmpty) return null;
    if (rule.substring(i).trim().isNotEmpty) return null;
    return _ProceduralParsed(selectorPart, action, arg);
  }
  return null;
}
