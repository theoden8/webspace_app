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

    test('converts simple exception rules (@@||domain^)', () {
      final result = parseAbpFilterListSync('@@||example.com^');
      expect(result.convertedCount, equals(1));
      expect(result.skippedCount, equals(0));
      expect(result.exceptionDomains, contains('example.com'));
    });

    test('skips complex exception rules (@@||domain/path)', () {
      final result = parseAbpFilterListSync(r'@@||example.com/some/path$script');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
      expect(result.exceptionDomains, isEmpty);
    });

    test('exception domains are case-insensitive', () {
      final result = parseAbpFilterListSync('@@||CDN.Example.COM^');
      expect(result.exceptionDomains, contains('cdn.example.com'));
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

    test('converts :has-text() in ## rules to text hide rules', () {
      final result = parseAbpFilterListSync('##.container:has-text(Sponsored)');
      expect(result.convertedCount, equals(1));
      expect(result.textHideRules[''], isNotEmpty);
      expect(result.textHideRules['']![0].selector, equals('.container'));
      expect(result.textHideRules['']![0].textPatterns, contains('Sponsored'));
    });

    test('converts :contains() in ## rules to text hide rules', () {
      final result = parseAbpFilterListSync('example.com##div.post:contains(Advertisement)');
      expect(result.convertedCount, equals(1));
      expect(result.textHideRules['example.com'], isNotEmpty);
      expect(result.textHideRules['example.com']![0].selector, equals('div.post'));
      expect(result.textHideRules['example.com']![0].textPatterns, contains('Advertisement'));
    });

    test('converts :-abp-has() to standard :has() in cosmetic rules', () {
      final result = parseAbpFilterListSync('##div:-abp-has(.ad-label)');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors[''], contains('div:has(.ad-label)'));
    });

    test('converts domain-specific :-abp-has() to :has()', () {
      final result = parseAbpFilterListSync('example.com##.feed-item:-abp-has(span.sponsored)');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors['example.com'], contains('.feed-item:has(span.sponsored)'));
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

    test('converts path-anchored rules with options stripped', () {
      // The wider-ABP work converts these — pattern after `$`-strip
      // is `||ads.example.com/path`, which matches the path-rule
      // regex. Options like `script,third-party` aren't enforced
      // (we don't classify resource types), but the URL still
      // matches at navigation time.
      final result = parseAbpFilterListSync(r'||ads.example.com/path$script,third-party');
      expect(result.convertedCount, equals(1));
      expect(result.skippedCount, equals(0));
      expect(result.blockedDomainPaths['ads.example.com']!.first.pathGlob,
          equals('/path'));
      expect(result.blockedDomains, isNot(contains('ads.example.com')),
          reason: 'path-anchored rule must not promote to a whole-domain block');
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
@@||cdn.example.com^
##div:-abp-has(.promo)
##.post:has-text(Sponsored)
''';
      final result = parseAbpFilterListSync(input);
      expect(result.convertedCount, equals(7)); // 2 domains + 1 exception + 2 cosmetic + 1 abp-has + 1 has-text
      expect(result.skippedCount, equals(1)); // redirect
      expect(result.blockedDomains, contains('ads.example.com'));
      expect(result.blockedDomains, contains('malware.com'));
      expect(result.exceptionDomains, contains('cdn.example.com'));
      expect(result.cosmeticSelectors[''], contains('.ad-banner'));
      expect(result.cosmeticSelectors[''], contains('div:has(.promo)'));
      expect(result.textHideRules['']![0].textPatterns, contains('Sponsored'));
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

    // ---- path-anchored network rules (||domain/path, ||domain^*x) ----

    test('converts ||domain/path rule to path-anchored entry', () {
      final result = parseAbpFilterListSync('||example.com/ads/');
      expect(result.convertedCount, equals(1));
      expect(result.blockedDomains, isEmpty,
          reason: 'path-anchored rule must not be promoted to whole-domain block');
      expect(result.blockedDomainPaths['example.com'], hasLength(1));
      expect(result.blockedDomainPaths['example.com']!.first.pathGlob,
          equals('/ads/'));
    });

    test('converts ||domain^/path rule (separator before path)', () {
      final result = parseAbpFilterListSync('||cdn.example.com^/track');
      expect(result.convertedCount, equals(1));
      expect(result.blockedDomainPaths['cdn.example.com']!.first.pathGlob,
          equals('/track'));
    });

    test('converts ||domain^*tracker glob path', () {
      final result = parseAbpFilterListSync('||example.com^*tracker.js');
      expect(result.convertedCount, equals(1));
      expect(result.blockedDomainPaths['example.com']!.first.pathGlob,
          equals('*tracker.js'));
    });

    test('aggregates multiple path globs against the same domain', () {
      const input = '''
||example.com/ads/
||example.com/track/
||example.com^*pixel.gif
''';
      final result = parseAbpFilterListSync(input);
      expect(result.blockedDomainPaths['example.com'], hasLength(3));
      expect(
          result.blockedDomainPaths['example.com']!
              .map((r) => r.pathGlob)
              .toList(),
          containsAll(['/ads/', '/track/', '*pixel.gif']));
    });

    test('keeps domain-only and path-anchored rules separate', () {
      const input = '''
||tracker.example.com^
||example.com/ads/banner
''';
      final result = parseAbpFilterListSync(input);
      expect(result.blockedDomains, contains('tracker.example.com'));
      expect(result.blockedDomains, isNot(contains('example.com')));
      expect(result.blockedDomainPaths['example.com'], hasLength(1));
    });

    test('compileDomainPathGlob translates wildcards correctly', () {
      // `*` and `^` both become `.*`; literal regex specials are escaped.
      final reSlash = compileDomainPathGlob('/ads/');
      expect(reSlash.hasMatch('/ads/banner.png'), isTrue);
      expect(reSlash.hasMatch('/foo/ads/'), isFalse,
          reason: 'glob is anchored to start of path, not a substring search');

      final reStar = compileDomainPathGlob('*tracker.js');
      expect(reStar.hasMatch('/foo/bar/tracker.js'), isTrue);
      expect(reStar.hasMatch('/foo/bar/tracker_js'), isFalse,
          reason: 'literal "." in glob must be escaped');

      final reCaret = compileDomainPathGlob('/track^');
      expect(reCaret.hasMatch('/track/abc'), isTrue,
          reason: 'ABP separator ^ should match path continuations');

      final reSpecials = compileDomainPathGlob('/foo+bar?baz');
      expect(reSpecials.hasMatch('/foo+bar?baz=1'), isTrue,
          reason: 'regex specials (+, ?) must be escaped to match literally');
    });

    test('extractPathAndQuery returns post-host portion', () {
      expect(extractPathAndQuery('https://example.com/ads/x.js'),
          equals('/ads/x.js'));
      expect(extractPathAndQuery('https://example.com'), equals('/'),
          reason: 'no-path URL should report root');
      expect(extractPathAndQuery('https://example.com/?q=1'), equals('/?q=1'));
      expect(extractPathAndQuery('https://example.com#frag'), equals('#frag'));
    });

    // ---- uBO :style() cosmetic extension ----

    test('converts global ##selector:style(decls) to a style rule', () {
      final result =
          parseAbpFilterListSync('##.banner:style(height: 1px !important)');
      expect(result.convertedCount, equals(1));
      expect(result.cosmeticSelectors, isEmpty,
          reason: ':style() rule must not double-emit a display:none rule');
      expect(result.styleRules[''], hasLength(1));
      expect(result.styleRules['']!.first.selector, equals('.banner'));
      expect(result.styleRules['']!.first.declarations,
          equals('height: 1px !important'));
    });

    test('converts domain-scoped :style() rule', () {
      final result =
          parseAbpFilterListSync('example.com##.ad:style(visibility: hidden)');
      expect(result.styleRules['example.com'], hasLength(1));
      expect(result.styleRules['example.com']!.first.selector, equals('.ad'));
      expect(result.styleRules['example.com']!.first.declarations,
          equals('visibility: hidden'));
    });

    test('multi-domain :style() applies to each listed domain', () {
      final result = parseAbpFilterListSync(
          'a.example,b.example##.banner:style(height: 0)');
      expect(result.styleRules['a.example'], hasLength(1));
      expect(result.styleRules['b.example'], hasLength(1));
    });

    test(':style() with empty declarations is skipped', () {
      final result = parseAbpFilterListSync('##.banner:style()');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    test(':style() without selector prefix is skipped', () {
      final result = parseAbpFilterListSync('##:style(color:red)');
      expect(result.convertedCount, equals(0));
      expect(result.skippedCount, equals(1));
    });

    // ---- uBO procedural action pseudos ----

    test('global ##sel:remove() emits a ProceduralActionRule', () {
      final result =
          parseAbpFilterListSync('##div.foo:has-text(REMOVE-ME):remove()');
      expect(result.proceduralActions[''], hasLength(1));
      final r = result.proceduralActions['']!.first;
      expect(r.selector, equals('div.foo:has-text(REMOVE-ME)'));
      expect(r.actionType, equals('remove'));
      expect(r.actionArg, isEmpty);
      expect(result.cosmeticSelectors, isEmpty,
          reason: 'procedural rule must NOT also emit a hide selector');
    });

    test('##sel:remove-attr(name) captures attribute name', () {
      final result = parseAbpFilterListSync(
          '##div[data-tracker]:remove-attr(data-tracker)');
      expect(result.proceduralActions[''], hasLength(1));
      final r = result.proceduralActions['']!.first;
      expect(r.selector, equals('div[data-tracker]'));
      expect(r.actionType, equals('remove-attr'));
      expect(r.actionArg, equals('data-tracker'));
    });

    test('##sel:remove-class(name) captures class name', () {
      final result = parseAbpFilterListSync('##div.foo:remove-class(bar)');
      expect(result.proceduralActions[''], hasLength(1));
      final r = result.proceduralActions['']!.first;
      expect(r.actionType, equals('remove-class'));
      expect(r.actionArg, equals('bar'));
    });

    test('domain-scoped procedural rule lands in the right bucket', () {
      final result = parseAbpFilterListSync(
          'example.com##div.ad:remove()\n##div.global:remove()');
      expect(result.proceduralActions['example.com'], hasLength(1));
      expect(result.proceduralActions[''], hasLength(1));
    });

    test('procedural rule JSON output matches engine wire format', () {
      final result =
          parseAbpFilterListSync('##div.foo:has-text(needle):remove()');
      final json = result.proceduralActions['']!.first.toEngineJson();
      expect(
          json,
          contains(
              '"selector":[{"type":"css-selector","arg":"div.foo:has-text(needle)"}]'));
      expect(json, contains('"action":"remove"'));
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
