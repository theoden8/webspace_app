import 'package:flutter/foundation.dart';

/// Result of parsing ABP filter list text.
class AbpParseResult {
  /// Domain-anchored network block rules for O(1) lookup.
  /// From `||domain.com^` rules (simple domain blocks without path/options).
  final Set<String> blockedDomains;

  /// CSS selectors to hide elements, grouped by scope.
  /// Key '' (empty) = global, key 'domain.com' = domain-specific.
  final Map<String, List<String>> cosmeticSelectors;

  final int convertedCount;
  final int skippedCount;

  const AbpParseResult({
    required this.blockedDomains,
    required this.cosmeticSelectors,
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

/// Regex matching simple domain-only rules: `||domain.com^` with optional
/// trailing options we can safely ignore for domain extraction.
final _simpleDomainRule = RegExp(r'^\|\|([a-zA-Z0-9._-]+)\^?$');

/// Parse a single line, adding to blockedDomains / cosmeticSelectors.
/// Returns true if converted, false if skipped.
bool _parseLine(
  String line,
  Set<String> blockedDomains,
  Map<String, List<String>> cosmeticSelectors,
) {
  // --- Cosmetic filter: ##selector or domain##selector ---
  final cosmeticIdx = line.indexOf('##');
  if (cosmeticIdx >= 0) {
    // Skip ABP extended CSS selectors (but NOT standard CSS :has() which browsers support)
    final afterHash = line.substring(cosmeticIdx);
    if (afterHash.startsWith('#?#') ||
        afterHash.startsWith('#\$#') ||
        afterHash.contains(':has-text(') ||
        afterHash.contains(':contains(') ||
        afterHash.contains(':-abp-') ||
        afterHash.contains(':matches-path(') ||
        afterHash.contains(':matches-attr(') ||
        afterHash.contains(':min-text-length(') ||
        afterHash.contains(':watch-attr(')) {
      return false;
    }

    final selector = line.substring(cosmeticIdx + 2).trim();
    if (selector.isEmpty) return false;

    // HTML filter (##^)
    if (selector.startsWith('^')) return false;

    final domainsStr = cosmeticIdx > 0 ? line.substring(0, cosmeticIdx) : '';

    if (domainsStr.isEmpty) {
      // Global cosmetic rule
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

  // Skip #?# / #$# extended selectors
  if (line.contains('#?#') || line.contains('#\$#')) {
    return false;
  }

  // --- Network rule ---
  // Skip exception rules (@@) — we only do domain blocking, no unblocking
  if (line.startsWith('@@')) return false;

  // Check for options
  final dollarIdx = line.lastIndexOf('\$');
  String pattern = line;
  if (dollarIdx > 0) {
    final afterDollar = line.substring(dollarIdx + 1);
    if (!afterDollar.contains('//') && !afterDollar.startsWith('/')) {
      // Check for unsupported options
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
  // These go into the hash set for O(1) lookup.
  // Complex patterns (paths, wildcards, options) are skipped to keep it fast.
  final match = _simpleDomainRule.firstMatch(pattern);
  if (match != null) {
    blockedDomains.add(match.group(1)!.toLowerCase());
    return true;
  }

  // Skip complex patterns — not worth the per-request regex cost
  return false;
}

/// Parse ABP filter text synchronously. Use [parseAbpFilterList] for isolate-based parsing.
AbpParseResult parseAbpFilterListSync(String text) {
  final blockedDomains = <String>{};
  final cosmeticSelectors = <String, List<String>>{};
  int converted = 0;
  int skipped = 0;

  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    // Skip empty lines, comments, and header lines
    if (trimmed.isEmpty ||
        trimmed.startsWith('!') ||
        trimmed.startsWith('[Adblock')) {
      continue;
    }

    if (_parseLine(trimmed, blockedDomains, cosmeticSelectors)) {
      converted++;
    } else {
      skipped++;
    }
  }

  return AbpParseResult(
    blockedDomains: blockedDomains,
    cosmeticSelectors: cosmeticSelectors,
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
