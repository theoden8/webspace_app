import 'package:webspace/services/page_js.dart';

/// A text-based hiding rule: hide elements whose `selector`-match
/// contents include any of `patterns`. Kept as a typedef so the
/// builder stays usable from any future caller that supplies its own
/// rule source.
typedef ContentBlockerTextRule = ({String selector, List<String> patterns});

/// A uBO `:style()` rule mirror — apply [declarations] to elements
/// matching [selector] instead of `display: none`.
typedef ContentBlockerStyleRule = ({String selector, String declarations});

List<Map<String, String>> _styleJson(List<ContentBlockerStyleRule> rules) => [
      for (final r in rules)
        {'selector': r.selector, 'declarations': r.declarations},
    ];

/// The DOCUMENT_START stylesheet hiding [selectors] and applying
/// [styleRules], or null when both are empty (nothing to inject).
String? buildContentBlockerEarlyCssShim({
  required List<String> selectors,
  List<ContentBlockerStyleRule> styleRules = const [],
}) {
  if (selectors.isEmpty && styleRules.isEmpty) return null;
  return PageJs.contentBlockerEarlyCss.withConfig({
    'selectors': selectors,
    'styleRules': _styleJson(styleRules),
  });
}

/// The post-load cosmetic shim: the early stylesheet plus the text-content
/// rules, or null when all three lists are empty.
String? buildContentBlockerCosmeticShim({
  required List<String> selectors,
  required List<ContentBlockerTextRule> textRules,
  List<ContentBlockerStyleRule> styleRules = const [],
}) {
  if (selectors.isEmpty && styleRules.isEmpty && textRules.isEmpty) {
    return null;
  }
  return PageJs.contentBlockerCosmetic.withConfig({
    'selectors': selectors,
    'styleRules': _styleJson(styleRules),
    'textRules': [
      for (final r in textRules) {'sel': r.selector, 'pats': r.patterns},
    ],
  });
}

/// ABP `$csp=` [directives] as a `<meta http-equiv>` policy.
String buildContentBlockerCspShim(String directives) =>
    PageJs.contentBlockerCsp.withConfig({'directives': directives});
