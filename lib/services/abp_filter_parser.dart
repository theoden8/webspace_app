import 'package:flutter/foundation.dart';

/// A text-based hiding rule: hide elements matching [selector] that contain
/// text matching any of [textPatterns].
class TextHideRule {
  final String selector;
  final List<String> textPatterns;

  const TextHideRule({required this.selector, required this.textPatterns});
}

/// Result of parsing ABP filter list text.
class AbpParseResult {
  /// Domain-anchored network block rules for O(1) lookup.
  final Set<String> blockedDomains;

  /// Exception domains (@@||domain^) that override blocked domains.
  final Set<String> exceptionDomains;

  /// CSS selectors to hide elements, grouped by scope.
  /// Key '' (empty) = global, key 'domain.com' = domain-specific.
  final Map<String, List<String>> cosmeticSelectors;

  /// Text-based hiding rules (from #?# rules with :-abp-contains), grouped by domain.
  final Map<String, List<TextHideRule>> textHideRules;

  final int convertedCount;
  final int skippedCount;

  const AbpParseResult({
    required this.blockedDomains,
    required this.exceptionDomains,
    required this.cosmeticSelectors,
    required this.textHideRules,
    required this.convertedCount,
    required this.skippedCount,
  });
}

/// Unsupported ABP options that cause a rule to be skipped.
const Set<String> _unsupportedOptions = {
  'redirect',
  'redirect-rule',
  'csp',
  'removeparam',
  'rewrite',
  'replace',
};

/// Regex matching simple domain-only rules: `||domain.com^`
final _simpleDomainRule = RegExp(r'^\|\|([a-zA-Z0-9._-]+)\^?$');

/// Parse :-abp-contains(/pattern1|pattern2/) or :-abp-contains(text) from a rule.
/// Returns list of text patterns to match, or null if not parseable.
List<String>? _extractAbpContainsPatterns(String rule) {
  // Find :-abp-contains( or :has-text(
  final containsRegex = RegExp(r':-abp-contains\(|:has-text\(');
  final match = containsRegex.firstMatch(rule);
  if (match == null) return null;

  final start = match.end;
  // Find matching closing paren, handling nested parens
  int depth = 1;
  int i = start;
  while (i < rule.length && depth > 0) {
    if (rule[i] == '(') depth++;
    if (rule[i] == ')') depth--;
    i++;
  }
  if (depth != 0) return null;

  var content = rule.substring(start, i - 1);

  // Handle regex syntax: /pattern/
  if (content.startsWith('/') && content.endsWith('/')) {
    content = content.substring(1, content.length - 1);
    // Split on | for alternation
    return content.split('|').where((s) => s.isNotEmpty).toList();
  }

  // Plain text match
  return [content];
}

/// Extract the container selector from a #?# rule.
/// e.g. "div.feed-shared-update-v2:-abp-has(...)" → "div.feed-shared-update-v2"
String? _extractContainerSelector(String selectorPart) {
  // Find the first :-abp- or :has-text( pseudo-class
  final pseudoIdx = selectorPart.indexOf(RegExp(r':-abp-|:has-text\('));
  if (pseudoIdx <= 0) return null;
  return selectorPart.substring(0, pseudoIdx).trim();
}

/// Parse a single line, adding to the appropriate data structure.
/// Returns true if converted, false if skipped.
bool _parseLine(
  String line,
  Set<String> blockedDomains,
  Set<String> exceptionDomains,
  Map<String, List<String>> cosmeticSelectors,
  Map<String, List<TextHideRule>> textHideRules,
) {
  // --- Extended CSS: #?# rules with text matching ---
  final extIdx = line.indexOf('#?#');
  if (extIdx >= 0) {
    final domainsStr = extIdx > 0 ? line.substring(0, extIdx) : '';
    final selectorPart = line.substring(extIdx + 3).trim();
    if (selectorPart.isEmpty) return false;

    // Extract text patterns from :-abp-contains or :has-text
    final patterns = _extractAbpContainsPatterns(selectorPart);
    if (patterns == null || patterns.isEmpty) return false;

    // Extract the container CSS selector (before the pseudo-class)
    final containerSelector = _extractContainerSelector(selectorPart);
    if (containerSelector == null || containerSelector.isEmpty) return false;

    final rule = TextHideRule(selector: containerSelector, textPatterns: patterns);

    if (domainsStr.isEmpty) {
      textHideRules.putIfAbsent('', () => []).add(rule);
    } else {
      for (final d in domainsStr.split(',')) {
        final trimmed = d.trim();
        if (trimmed.isEmpty || trimmed.startsWith('~')) continue;
        textHideRules.putIfAbsent(trimmed, () => []).add(rule);
      }
    }
    return true;
  }

  // --- Cosmetic filter: ##selector or domain##selector ---
  final cosmeticIdx = line.indexOf('##');
  if (cosmeticIdx >= 0) {
    final afterHash = line.substring(cosmeticIdx);

    // Skip snippet rules (#$#) and truly unsupported pseudo-classes
    if (afterHash.startsWith('#\$#') ||
        afterHash.contains(':matches-path(') ||
        afterHash.contains(':matches-attr(') ||
        afterHash.contains(':min-text-length(') ||
        afterHash.contains(':watch-attr(')) {
      return false;
    }

    var selector = line.substring(cosmeticIdx + 2).trim();
    if (selector.isEmpty) return false;

    // HTML filter (##^)
    if (selector.startsWith('^')) return false;

    final domainsStr = cosmeticIdx > 0 ? line.substring(0, cosmeticIdx) : '';

    // Handle :has-text() and :contains() — convert to TextHideRule
    if (selector.contains(':has-text(') || selector.contains(':contains(')) {
      final patterns = _extractAbpContainsPatterns(
          selector.replaceAll(':contains(', ':-abp-contains(')
                   .replaceAll(':has-text(', ':-abp-contains('));
      if (patterns == null || patterns.isEmpty) return false;

      final containerSelector = _extractContainerSelector(
          selector.replaceAll(':contains(', ':-abp-contains(')
                   .replaceAll(':has-text(', ':-abp-contains('));
      if (containerSelector == null || containerSelector.isEmpty) return false;

      final rule = TextHideRule(selector: containerSelector, textPatterns: patterns);
      if (domainsStr.isEmpty) {
        textHideRules.putIfAbsent('', () => []).add(rule);
      } else {
        for (final d in domainsStr.split(',')) {
          final trimmed = d.trim();
          if (trimmed.isEmpty || trimmed.startsWith('~')) continue;
          textHideRules.putIfAbsent(trimmed, () => []).add(rule);
        }
      }
      return true;
    }

    // Rewrite :-abp-has() to standard CSS :has()
    if (selector.contains(':-abp-has(')) {
      selector = selector.replaceAll(':-abp-has(', ':has(');
    }

    // Skip remaining ABP-only pseudo-classes that can't be mapped
    if (selector.contains(':-abp-')) {
      return false;
    }

    if (domainsStr.isEmpty) {
      cosmeticSelectors.putIfAbsent('', () => []).add(selector);
    } else {
      for (final d in domainsStr.split(',')) {
        final trimmed = d.trim();
        if (trimmed.isEmpty || trimmed.startsWith('~')) continue;
        cosmeticSelectors.putIfAbsent(trimmed, () => []).add(selector);
      }
    }
    return true;
  }

  // Skip #$# snippet rules
  if (line.contains('#\$#')) {
    return false;
  }

  // --- Network rule ---
  // Exception rules: @@||domain^ → allowlist domain
  if (line.startsWith('@@')) {
    final exceptionPattern = line.substring(2);
    final exMatch = _simpleDomainRule.firstMatch(exceptionPattern);
    if (exMatch != null) {
      exceptionDomains.add(exMatch.group(1)!.toLowerCase());
      return true;
    }
    return false;
  }

  // Check for options
  final dollarIdx = line.lastIndexOf('\$');
  String pattern = line;
  if (dollarIdx > 0) {
    final afterDollar = line.substring(dollarIdx + 1);
    if (!afterDollar.contains('//') && !afterDollar.startsWith('/')) {
      for (final opt in afterDollar.split(',')) {
        final trimmed = opt.trim().toLowerCase();
        if (_unsupportedOptions.any((u) => trimmed == u || trimmed.startsWith('$u='))) {
          return false;
        }
      }
      pattern = line.substring(0, dollarIdx);
    }
  }

  // Skip regex patterns
  if (pattern.startsWith('/') && pattern.endsWith('/') && pattern.length > 1) {
    return false;
  }

  // Only convert simple domain-anchored rules: ||domain.com^
  final match = _simpleDomainRule.firstMatch(pattern);
  if (match != null) {
    blockedDomains.add(match.group(1)!.toLowerCase());
    return true;
  }

  return false;
}

/// Parse ABP filter text synchronously.
AbpParseResult parseAbpFilterListSync(String text) {
  final blockedDomains = <String>{};
  final exceptionDomains = <String>{};
  final cosmeticSelectors = <String, List<String>>{};
  final textHideRules = <String, List<TextHideRule>>{};
  int converted = 0;
  int skipped = 0;

  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('!') ||
        trimmed.startsWith('[Adblock')) {
      continue;
    }

    if (_parseLine(trimmed, blockedDomains, exceptionDomains, cosmeticSelectors, textHideRules)) {
      converted++;
    } else {
      skipped++;
    }
  }

  return AbpParseResult(
    blockedDomains: blockedDomains,
    exceptionDomains: exceptionDomains,
    cosmeticSelectors: cosmeticSelectors,
    textHideRules: textHideRules,
    convertedCount: converted,
    skippedCount: skipped,
  );
}

/// Parse ABP filter text in an isolate to avoid blocking the UI thread.
Future<AbpParseResult> parseAbpFilterList(String text) {
  return compute(_parseInIsolate, text);
}

AbpParseResult _parseInIsolate(String text) {
  return parseAbpFilterListSync(text);
}
