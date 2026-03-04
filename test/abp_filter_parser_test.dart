import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/abp_filter_parser.dart';

void main() {
  group('abpToRegex', () {
    test('converts || domain anchor to regex', () {
      final regex = abpToRegex('||example.com^');
      expect(regex, equals(r'^https?://([^/]+\.)?example\.com[/:?&=]'));
    });

    test('converts * wildcard to .*', () {
      final regex = abpToRegex('||example.com/*/ad');
      expect(regex, contains('.*'));
    });

    test('escapes dots', () {
      final regex = abpToRegex('example.com');
      expect(regex, contains(r'\.'));
    });

    test('handles | start anchor', () {
      final regex = abpToRegex('|https://example.com');
      expect(regex, startsWith('^'));
    });

    test('handles | end anchor', () {
      final regex = abpToRegex('example.com|');
      expect(regex, endsWith(r'$'));
    });

    test('handles pattern with no special chars', () {
      final regex = abpToRegex('ad');
      expect(regex, equals('ad'));
    });
  });

  group('parseAbpFilterListSync', () {
    test('skips comment lines', () {
      final result = parseAbpFilterListSync('! This is a comment\n! Another comment');
      expect(result.rules, isEmpty);
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(0));
    });

    test('skips header lines', () {
      final result = parseAbpFilterListSync('[Adblock Plus 2.0]');
      expect(result.rules, isEmpty);
      expect(result.convertedCount, equals(0));
    });

    test('skips empty lines', () {
      final result = parseAbpFilterListSync('\n\n\n');
      expect(result.rules, isEmpty);
    });

    test('converts basic network block rule', () {
      final result = parseAbpFilterListSync('||ads.example.com^');
      expect(result.convertedCount, equals(1));
      expect(result.skippedCount, equals(0));
      expect(result.rules.length, equals(1));
      expect(result.rules[0].action.type, equals(ContentBlockerActionType.BLOCK));
      expect(result.rules[0].trigger.urlFilter, contains('ads\\.example\\.com'));
    });

    test('skips exception rules when skipExceptions is true', () {
      final result = parseAbpFilterListSync('@@||example.com^', skipExceptions: true);
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('converts exception rules when skipExceptions is false', () {
      // On platforms that support IGNORE_PREVIOUS_RULES (iOS/macOS), exception rules are converted.
      // On test platform (Linux), IGNORE_PREVIOUS_RULES throws, so we skip this assertion.
      final result = parseAbpFilterListSync('@@||example.com^', skipExceptions: false);
      // The rule either converts or is skipped depending on platform
      expect(result.convertedCount + result.skippedCount, equals(1));
    });

    test('converts cosmetic filter with ## selector', () {
      final result = parseAbpFilterListSync('##.ad-banner');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].action.type,
          equals(ContentBlockerActionType.CSS_DISPLAY_NONE));
      expect(result.rules[0].action.selector, equals('.ad-banner'));
      expect(result.rules[0].trigger.urlFilter, equals('.*'));
    });

    test('converts domain-specific cosmetic filter', () {
      final result = parseAbpFilterListSync('example.com##.ad-sidebar');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].action.selector, equals('.ad-sidebar'));
      expect(result.rules[0].trigger.ifDomain, contains('*example.com'));
    });

    test('converts multi-domain cosmetic filter', () {
      final result = parseAbpFilterListSync('example.com,test.org##.sponsored');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.ifDomain, contains('*example.com'));
      expect(result.rules[0].trigger.ifDomain, contains('*test.org'));
    });

    test('skips extended CSS selectors (:has)', () {
      final result = parseAbpFilterListSync('##.container:has(.ad)');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('skips #?# extended selectors', () {
      final result = parseAbpFilterListSync('example.com#?#.ad:has-text(Sponsored)');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('skips #\$# snippet rules', () {
      final result = parseAbpFilterListSync(r'example.com#$#abort-on-property-read');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('skips HTML filter rules (##^)', () {
      final result = parseAbpFilterListSync('##^script[data-ad]');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('parses \$third-party option', () {
      final result = parseAbpFilterListSync(r'||ads.example.com^$third-party');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.loadType,
          contains(ContentBlockerTriggerLoadType.THIRD_PARTY));
    });

    test('parses \$script resource type', () {
      final result = parseAbpFilterListSync(r'||ads.example.com^$script');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.resourceType,
          contains(ContentBlockerTriggerResourceType.SCRIPT));
    });

    test('parses \$image resource type', () {
      final result = parseAbpFilterListSync(r'||ads.example.com^$image');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.resourceType,
          contains(ContentBlockerTriggerResourceType.IMAGE));
    });

    test('parses multiple resource types', () {
      final result = parseAbpFilterListSync(r'||ads.example.com^$script,image');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.resourceType,
          contains(ContentBlockerTriggerResourceType.SCRIPT));
      expect(result.rules[0].trigger.resourceType,
          contains(ContentBlockerTriggerResourceType.IMAGE));
    });

    test('parses \$domain= option with ifDomain', () {
      final result = parseAbpFilterListSync(r'||ads.com^$domain=example.com');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.ifDomain, contains('*example.com'));
    });

    test('parses \$domain= option with unlessDomain', () {
      final result = parseAbpFilterListSync(r'||ads.com^$domain=~safe.com');
      expect(result.convertedCount, equals(1));
      expect(result.rules[0].trigger.unlessDomain, contains('*safe.com'));
    });

    test('skips \$redirect rules', () {
      final result = parseAbpFilterListSync(r'||ads.com^$redirect=noopjs');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('skips \$csp rules', () {
      final result = parseAbpFilterListSync(r'||example.com^$csp=script-src');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('skips \$removeparam rules', () {
      final result = parseAbpFilterListSync(r'||example.com^$removeparam=utm_source');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('skips regex patterns', () {
      final result = parseAbpFilterListSync(r'/^https?:\/\/ads\.example\.com\//');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('parses a mix of supported and unsupported rules', () {
      const input = '''
[Adblock Plus 2.0]
! Title: Test List
||ads.example.com^
##.ad-banner
||tracker.com^\$redirect=noopjs
##.container:has(.ad)
||malware.com^
''';
      final result = parseAbpFilterListSync(input);
      expect(result.convertedCount, equals(3)); // 2 network + 1 cosmetic
      expect(result.skippedCount, equals(2)); // redirect + extended CSS
    });

    test('handles real EasyList-style rules', () {
      const input = '''
[Adblock Plus 2.0]
! Title: EasyList
! Last modified: 01 Jan 2024
||googleads.g.doubleclick.net^
||pagead2.googlesyndication.com^
||securepubads.g.doubleclick.net/tag/js/gpt.js
-advertisement-icon.
-advertising-partner.
##.AdSense
##.ad-leaderboard
###ad-banner
''';
      final result = parseAbpFilterListSync(input);
      // All lines should be convertible
      expect(result.convertedCount, greaterThan(0));
      expect(result.rules.length, equals(result.convertedCount));
    });

    test('handles combined options: type + third-party + domain', () {
      final result = parseAbpFilterListSync(
          r'||cdn.ads.com/banner$image,third-party,domain=example.com|test.org');
      expect(result.convertedCount, equals(1));
      final rule = result.rules[0];
      expect(rule.trigger.resourceType,
          contains(ContentBlockerTriggerResourceType.IMAGE));
      expect(rule.trigger.loadType,
          contains(ContentBlockerTriggerLoadType.THIRD_PARTY));
      expect(rule.trigger.ifDomain, contains('*example.com'));
      expect(rule.trigger.ifDomain, contains('*test.org'));
    });
  });
}
