import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/abp_filter_parser.dart';

void main() {
  group('parseAbpFilterListSync', () {
    test('skips comment lines', () {
      final result = parseAbpFilterListSync('! This is a comment\n! Another comment');
      expect(result.blockedDomains, isEmpty);
      expect(result.cosmeticSelectors, isEmpty);
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(0));
    });

    test('skips header lines', () {
      final result = parseAbpFilterListSync('[Adblock Plus 2.0]');
      expect(result.convertedCount, equals(0));
    });

    test('skips empty lines', () {
      final result = parseAbpFilterListSync('\n\n\n');
      expect(result.blockedDomains, isEmpty);
    });

    test('converts simple domain block rule', () {
      final result = parseAbpFilterListSync('||ads.example.com^');
      expect(result.convertedCount, equals(1));
      expect(result.skippedCount, equals(0));
      expect(result.blockedDomains, contains('ads.example.com'));
    });

    test('converts domain rule without trailing ^', () {
      final result = parseAbpFilterListSync('||tracker.example.com');
      expect(result.blockedDomains, contains('tracker.example.com'));
    });

    test('skips exception rules (@@)', () {
      final result = parseAbpFilterListSync('@@||example.com^');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('converts global cosmetic filter', () {
      final result = parseAbpFilterListSync('##.ad-banner');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors[''], contains('.ad-banner'));
    });

    test('converts domain-specific cosmetic filter', () {
      final result = parseAbpFilterListSync('example.com##.ad-sidebar');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors['example.com'], contains('.ad-sidebar'));
    });

    test('converts multi-domain cosmetic filter', () {
      final result = parseAbpFilterListSync('example.com,test.org##.sponsored');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors['example.com'], contains('.sponsored'));
      expect(result.cosmeticSelectors['test.org'], contains('.sponsored'));
    });

    test('converts standard CSS :has() selectors', () {
      final result = parseAbpFilterListSync('##.container:has(.ad)');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors[''], contains('.container:has(.ad)'));
    });

    test('skips ABP-only :has-text() selectors', () {
      final result = parseAbpFilterListSync('##.container:has-text(Sponsored)');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test('converts #?# rules with :-abp-contains to text hide rules', () {
      final result = parseAbpFilterListSync(
        r'linkedin.com#?#div.feed-shared-update-v2:-abp-has(span:-abp-contains(/Promoted|Sponsored/))'
      );
      expect(result.convertedCount, equals(1));
      expect(result.textHideRules['linkedin.com'], isNotEmpty);
      expect(result.textHideRules['linkedin.com']![0].selector, equals('div.feed-shared-update-v2'));
      expect(result.textHideRules['linkedin.com']![0].textPatterns, containsAll(['Promoted', 'Sponsored']));
    });

    test('skips #?# rules without text matching', () {
      final result = parseAbpFilterListSync('example.com#?#.ad:style(color: red)');
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

    test('skips complex path rules (not domain-only)', () {
      // Rules with paths/wildcards are skipped for performance
      final result = parseAbpFilterListSync(r'||ads.example.com/path$script,third-party');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
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
      expect(result.convertedCount, equals(4)); // 2 domains + 1 cosmetic + 1 :has() cosmetic
      expect(result.skippedCount, equals(1)); // redirect
      expect(result.blockedDomains, contains('ads.example.com'));
      expect(result.blockedDomains, contains('malware.com'));
      expect(result.cosmeticSelectors[''], contains('.ad-banner'));
    });

    test('handles real EasyList-style rules', () {
      const input = '''
[Adblock Plus 2.0]
! Title: EasyList
||googleads.g.doubleclick.net^
||pagead2.googlesyndication.com^
##.AdSense
##.ad-leaderboard
###ad-banner
''';
      final result = parseAbpFilterListSync(input);
      expect(result.blockedDomains, contains('googleads.g.doubleclick.net'));
      expect(result.blockedDomains, contains('pagead2.googlesyndication.com'));
      expect(result.cosmeticSelectors[''], containsAll(['.AdSense', '.ad-leaderboard', '#ad-banner']));
    });

    test('domain blocking is case-insensitive', () {
      final result = parseAbpFilterListSync('||ADS.Example.COM^');
      expect(result.blockedDomains, contains('ads.example.com'));
    });

    test('aggregates selectors from multiple rules', () {
      const input = '''
##.ad-banner
##.ad-sidebar
example.com##.promoted
example.com##.sponsored
''';
      final result = parseAbpFilterListSync(input);
      expect(result.cosmeticSelectors['']!.length, equals(2));
      expect(result.cosmeticSelectors['example.com']!.length, equals(2));
    });
  });
}
