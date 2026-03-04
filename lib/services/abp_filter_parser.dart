import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Result of parsing ABP filter list text into ContentBlocker rules.
class AbpParseResult {
  final List<ContentBlocker> rules;
  final int convertedCount;
  final int skippedCount;

  const AbpParseResult({
    required this.rules,
    required this.convertedCount,
    required this.skippedCount,
  });
}

/// ABP option-to-resource-type mapping.
const Map<String, ContentBlockerTriggerResourceType> _resourceTypeMap = {
  'script': ContentBlockerTriggerResourceType.SCRIPT,
  'image': ContentBlockerTriggerResourceType.IMAGE,
  'stylesheet': ContentBlockerTriggerResourceType.STYLE_SHEET,
  'font': ContentBlockerTriggerResourceType.FONT,
  'media': ContentBlockerTriggerResourceType.MEDIA,
  'subdocument': ContentBlockerTriggerResourceType.DOCUMENT,
  'xmlhttprequest': ContentBlockerTriggerResourceType.RAW,
  'other': ContentBlockerTriggerResourceType.RAW,
};

/// Unsupported ABP options that cause a rule to be skipped.
const Set<String> _unsupportedOptions = {
  'redirect',
  'redirect-rule',
  'csp',
  'removeparam',
  'rewrite',
  'replace',
};

/// Convert ABP filter syntax to a URL filter regex pattern.
/// `||` means "beginning of domain", `^` means separator, `*` means wildcard.
String abpToRegex(String pattern) {
  final buf = StringBuffer();

  int i = 0;

  // Handle || prefix: match domain start
  if (pattern.startsWith('||')) {
    buf.write('^https?://([^/]+\\.)?');
    i = 2;
  } else if (pattern.startsWith('|')) {
    buf.write('^');
    i = 1;
  }

  // Handle | suffix
  final hasEndAnchor = pattern.endsWith('|') && !pattern.endsWith('||');
  final end = hasEndAnchor ? pattern.length - 1 : pattern.length;

  for (; i < end; i++) {
    final c = pattern[i];
    switch (c) {
      case '*':
        buf.write('.*');
        break;
      case '^':
        buf.write('[/:?&=]');
        break;
      case '.':
        buf.write('\\.');
        break;
      case '?':
        buf.write('\\?');
        break;
      case '+':
        buf.write('\\+');
        break;
      case '(':
        buf.write('\\(');
        break;
      case ')':
        buf.write('\\)');
        break;
      case '[':
        buf.write('\\[');
        break;
      case ']':
        buf.write('\\]');
        break;
      case '{':
        buf.write('\\{');
        break;
      case '}':
        buf.write('\\}');
        break;
      default:
        buf.write(c);
    }
  }

  if (hasEndAnchor) {
    buf.write('\$');
  }

  return buf.toString();
}

/// Parse a single ABP filter line into a ContentBlocker, or null if unsupported.
/// Returns null and increments skip counting for unsupported rules.
/// Set [skipExceptions] to filter out IGNORE_PREVIOUS_RULES
/// (unsupported on Android and other non-iOS/macOS platforms).
ContentBlocker? _parseLine(String line, {required bool skipExceptions}) {
  // Cosmetic filter: ##selector or domain##selector
  final cosmeticIdx = line.indexOf('##');
  if (cosmeticIdx >= 0) {
    // Skip extended CSS selectors
    final afterHash = line.substring(cosmeticIdx);
    if (afterHash.startsWith('#?#') ||
        afterHash.startsWith('#\$#') ||
        afterHash.contains(':has(') ||
        afterHash.contains(':has-text(') ||
        afterHash.contains(':-abp-')) {
      return null;
    }

    final selector = line.substring(cosmeticIdx + 2).trim();
    if (selector.isEmpty) return null;

    // HTML filter (##^)
    if (selector.startsWith('^')) return null;

    final domains = cosmeticIdx > 0 ? line.substring(0, cosmeticIdx) : '';

    final List<String> ifDomain = [];
    if (domains.isNotEmpty) {
      for (final d in domains.split(',')) {
        final trimmed = d.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('~')) continue; // Exclude domain, skip for simplicity
        ifDomain.add('*$trimmed');
      }
      if (ifDomain.isEmpty) return null;
    }

    return ContentBlocker(
      trigger: ContentBlockerTrigger(
        urlFilter: '.*',
        ifDomain: ifDomain,
      ),
      action: ContentBlockerAction(
        type: ContentBlockerActionType.CSS_DISPLAY_NONE,
        selector: selector,
      ),
    );
  }

  // Check for #?# / #$# extended selectors (if ## was not found above)
  if (line.contains('#?#') || line.contains('#\$#')) {
    return null;
  }

  // Network rule
  bool isException = false;
  String rulePart = line;

  if (rulePart.startsWith('@@')) {
    isException = true;
    rulePart = rulePart.substring(2);
    // IGNORE_PREVIOUS_RULES only supported on iOS/macOS
    if (skipExceptions) return null;
  }

  // Split options
  String pattern = rulePart;
  String optionsPart = '';

  // Find the last $ that's not inside a regex
  final dollarIdx = rulePart.lastIndexOf('\$');
  if (dollarIdx > 0) {
    final beforeDollar = rulePart.substring(0, dollarIdx);
    final afterDollar = rulePart.substring(dollarIdx + 1);
    // Only treat as options if the part after $ looks like options
    // (contains known option keywords or comma-separated values)
    if (!afterDollar.contains('//') && !afterDollar.startsWith('/')) {
      pattern = beforeDollar;
      optionsPart = afterDollar;
    }
  }

  // Skip regex patterns (enclosed in /.../)
  if (pattern.startsWith('/') && pattern.endsWith('/')) {
    return null;
  }

  // Parse options
  final List<ContentBlockerTriggerResourceType> resourceTypes = [];
  final List<ContentBlockerTriggerLoadType> loadTypes = [];
  final List<String> ifDomain = [];
  final List<String> unlessDomain = [];

  if (optionsPart.isNotEmpty) {
    for (final opt in optionsPart.split(',')) {
      final trimmed = opt.trim().toLowerCase();
      if (trimmed.isEmpty) continue;

      // Check for unsupported options
      if (_unsupportedOptions.any((u) => trimmed == u || trimmed.startsWith('$u='))) {
        return null;
      }

      if (trimmed == 'third-party' || trimmed == '3p') {
        loadTypes.add(ContentBlockerTriggerLoadType.THIRD_PARTY);
      } else if (trimmed == '~third-party' || trimmed == '~3p' || trimmed == '1p') {
        loadTypes.add(ContentBlockerTriggerLoadType.FIRST_PARTY);
      } else if (trimmed.startsWith('domain=')) {
        final domainList = trimmed.substring(7);
        for (final d in domainList.split('|')) {
          if (d.startsWith('~')) {
            unlessDomain.add('*${d.substring(1)}');
          } else {
            ifDomain.add('*$d');
          }
        }
      } else if (_resourceTypeMap.containsKey(trimmed)) {
        resourceTypes.add(_resourceTypeMap[trimmed]!);
      } else if (trimmed.startsWith('~')) {
        // Negated resource type, ignore
      }
      // Other unknown options: ignore silently
    }
  }

  // Convert pattern to regex
  final urlFilter = abpToRegex(pattern);
  if (urlFilter.isEmpty) return null;

  if (isException) {
    try {
      return ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: urlFilter,
          resourceType: resourceTypes,
          loadType: loadTypes,
          ifDomain: ifDomain,
          unlessDomain: unlessDomain,
        ),
        action: ContentBlockerAction(
          type: ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
        ),
      );
    } catch (_) {
      // IGNORE_PREVIOUS_RULES not supported on this platform
      return null;
    }
  }

  return ContentBlocker(
    trigger: ContentBlockerTrigger(
      urlFilter: urlFilter,
      resourceType: resourceTypes,
      loadType: loadTypes,
      ifDomain: ifDomain,
      unlessDomain: unlessDomain,
    ),
    action: ContentBlockerAction(
      type: ContentBlockerActionType.BLOCK,
    ),
  );
}

/// Parse ABP filter text synchronously. Use [parseAbpFilterList] for isolate-based parsing.
/// Set [skipExceptions] to true on platforms that don't support IGNORE_PREVIOUS_RULES
/// (Android, Linux, Windows — only iOS/macOS support it).
AbpParseResult parseAbpFilterListSync(String text, {bool skipExceptions = false}) {
  final rules = <ContentBlocker>[];
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

    final rule = _parseLine(trimmed, skipExceptions: skipExceptions);
    if (rule != null) {
      rules.add(rule);
      converted++;
    } else {
      skipped++;
    }
  }

  return AbpParseResult(
    rules: rules,
    convertedCount: converted,
    skippedCount: skipped,
  );
}

/// Parse ABP filter text in an isolate to avoid blocking the UI thread.
Future<AbpParseResult> parseAbpFilterList(String text, {bool skipExceptions = false}) {
  return compute(
    _parseInIsolate,
    _ParseArgs(text: text, skipExceptions: skipExceptions),
  );
}

class _ParseArgs {
  final String text;
  final bool skipExceptions;
  const _ParseArgs({required this.text, required this.skipExceptions});
}

AbpParseResult _parseInIsolate(_ParseArgs args) {
  return parseAbpFilterListSync(args.text, skipExceptions: args.skipExceptions);
}
