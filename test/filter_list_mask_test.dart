@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/filter_list_mask.dart';

/// Single-line convenience: the rewriter works on whole lists, tests read
/// better one rule at a time.
String scope(String rule, [List<String> hosts = const ['masked.example']]) =>
    scopeRulesAwayFromHosts(rule, hosts).trim();

void main() {
  group('scopeRulesAwayFromHosts — network rules (CB-015)', () {
    test('no hosts leaves the list byte-identical', () {
      const text = '||ads.example^\n! comment\nexample.com##.ad\n';
      expect(scopeRulesAwayFromHosts(text, const []), text);
    });

    test('a bare rule gains a negated domain option', () {
      expect(scope('||ads.example^'), r'||ads.example^$domain=~masked.example');
    });

    test('existing options are extended, not replaced', () {
      expect(scope(r'||ads.example^$script,third-party'),
          r'||ads.example^$script,third-party,domain=~masked.example');
    });

    test('an existing domain option is merged in place', () {
      expect(scope(r'||ads.example^$domain=news.example'),
          r'||ads.example^$domain=news.example|~masked.example');
    });

    test('the from= alias is merged too, since a second domain= would win',
        () {
      expect(scope(r'||ads.example^$from=news.example,script'),
          r'||ads.example^$from=news.example|~masked.example,script');
    });

    test('every masked host is negated', () {
      expect(scope('||ads.example^', ['a.example', 'b.example']),
          r'||ads.example^$domain=~a.example|~b.example');
    });

    test('exception rules are scoped like blocking rules', () {
      expect(scope('@@||ads.example^'),
          r'@@||ads.example^$domain=~masked.example');
    });

    test(r'a $ inside the pattern is not mistaken for the option separator',
        () {
      // The crate takes the LAST `$`; appending our own would otherwise
      // swallow the rule's real options into the pattern.
      expect(scope(r'||ads.example/a$b^$script'),
          r'||ads.example/a$b^$script,domain=~masked.example');
    });

    test(r'badfilter rules are left alone', () {
      // A $badfilter cancels a rule by matching its options, so scoping it
      // would revive the cancelled rule for every site.
      expect(scope(r'||ads.example^$badfilter'), r'||ads.example^$badfilter');
    });

    test('comments and list headers are untouched', () {
      expect(scope('! EasyList'), '! EasyList');
      expect(scope('[Adblock Plus 2.0]'), '[Adblock Plus 2.0]');
      expect(scope('# hosts-style comment'), '# hosts-style comment');
    });
  });

  group('scopeRulesAwayFromHosts — cosmetic rules (CB-015)', () {
    test('a generic hide gains a negated hostname', () {
      expect(scope('##.ad-banner'), '~masked.example##.ad-banner');
    });

    test('a domain-scoped rule keeps its domains and gains the negation', () {
      expect(scope('news.example##.ad'), 'news.example,~masked.example##.ad');
    });

    test('unhide rules are left alone', () {
      // adblock-rust rejects a rule that is both an unhide and
      // domain-negated (DoubleNegation), which would drop it everywhere.
      expect(scope('news.example#@#.ad'), 'news.example#@#.ad');
      expect(scope('#@#.ad'), '#@#.ad');
    });

    test('generic scriptlets are left alone', () {
      // A generic rule with only negated hostnames stays generic only for
      // plain hides; a scriptlet would end up applying nowhere.
      expect(scope('##+js(nowoif)'), '##+js(nowoif)');
    });

    test('generic procedural and action rules are left alone', () {
      expect(scope('##.ad:remove()'), '##.ad:remove()');
      expect(scope('##.ad:has-text(sponsored)'), '##.ad:has-text(sponsored)');
      expect(scope('#?#.ad:-abp-has(.x)'), '#?#.ad:-abp-has(.x)');
    });

    test('domain-scoped procedural rules are scoped', () {
      expect(scope('news.example##.ad:remove()'),
          'news.example,~masked.example##.ad:remove()');
    });

    test('a url with a lone # stays a network rule', () {
      expect(scope('||ads.example/x#y'),
          r'||ads.example/x#y$domain=~masked.example');
    });
  });

  group('scopeRulesAwayFromHosts — whole lists', () {
    test('every line is preserved, one per line', () {
      const text = '! header\n||a.example^\nb.example##.ad\n\n##.generic\n';
      final out = scopeRulesAwayFromHosts(text, const ['masked.example']);
      expect(out.split('\n').where((l) => l.isNotEmpty).length, 4);
      expect(out, contains(r'||a.example^$domain=~masked.example'));
      expect(out, contains('b.example,~masked.example##.ad'));
      expect(out, contains('~masked.example##.generic'));
    });
  });

  group('the engine agrees with the rewrite (CB-015)', () {
    final libExists = _libraryExists();
    const skipReason = 'library not built';

    test('a masked network rule stops blocking on the masked site only', () {
      final engine = AdblockEngine.load(
          '${scope('||ads.example^')}\n')!;
      addTearDown(engine.dispose);
      expect(
        engine.shouldBlock('https://ads.example/x.js',
            sourceUrl: 'https://masked.example/', requestType: 'script'),
        isFalse,
        reason: 'the site that switched the list off must not be blocked',
      );
      expect(
        engine.shouldBlock('https://ads.example/x.js',
            sourceUrl: 'https://other.example/', requestType: 'script'),
        isTrue,
        reason: 'every other site still gets the rule',
      );
    }, skip: libExists ? false : skipReason);

    test('the negation covers subdomains of the masked host', () {
      final engine = AdblockEngine.load('${scope('||ads.example^')}\n')!;
      addTearDown(engine.dispose);
      expect(
        engine.shouldBlock('https://ads.example/x.js',
            sourceUrl: 'https://www.masked.example/', requestType: 'script'),
        isFalse,
      );
    }, skip: libExists ? false : skipReason);

    test('merging into an existing domain option keeps that scoping', () {
      final engine = AdblockEngine.load(
          '${scope(r'||ads.example^$domain=news.example')}\n')!;
      addTearDown(engine.dispose);
      expect(
        engine.shouldBlock('https://ads.example/x.js',
            sourceUrl: 'https://news.example/', requestType: 'script'),
        isTrue,
      );
      expect(
        engine.shouldBlock('https://ads.example/x.js',
            sourceUrl: 'https://unrelated.example/', requestType: 'script'),
        isFalse,
        reason: 'the rule was already scoped to news.example',
      );
    }, skip: libExists ? false : skipReason);

    test('a masked generic hide stays generic and is excepted on the site',
        () {
      final engine = AdblockEngine.load('${scope('##.ad-banner')}\n')!;
      addTearDown(engine.dispose);
      final elsewhere = engine.cosmeticResources('https://other.example/');
      final masked = engine.cosmeticResources('https://masked.example/');
      expect((masked?['exceptions'] as List?)?.cast<String>(),
          contains('.ad-banner'),
          reason: 'the masked site must see it as an exception');
      // The selector reaches other sites through the generic class scanner,
      // which filters on the same exception set.
      expect(
        engine.hiddenClassIdSelectors({'ad-banner'}, const {},
            exceptions: (elsewhere?['exceptions'] as List? ?? const [])
                .cast<String>()
                .toSet()),
        contains('.ad-banner'),
      );
      expect(
        engine.hiddenClassIdSelectors({'ad-banner'}, const {},
            exceptions: (masked?['exceptions'] as List? ?? const [])
                .cast<String>()
                .toSet()),
        isEmpty,
      );
    }, skip: libExists ? false : skipReason);

    test('option-carrying rules mask too', () {
      // $removeparam, $csp and $important all ride network filters, so the
      // domain option reaches them; a rewrite that mis-merged the option list
      // would silently drop them instead.
      final engine = AdblockEngine.load(
          '${scope(r'$removeparam=utm_source')}\n'
          '${scope(r'||x.example^$csp=script-src none')}\n'
          '${scope(r'||y.example^$important')}\n')!;
      addTearDown(engine.dispose);
      const url = 'https://x.example/a?utm_source=z&b=1';
      expect(
          engine.rewrittenUrl(url,
              sourceUrl: 'https://other.example/', requestType: 'document'),
          'https://x.example/a?b=1');
      expect(
          engine.rewrittenUrl(url,
              sourceUrl: 'https://masked.example/', requestType: 'document'),
          isNull);
      expect(
          engine.cspFor('https://x.example/',
              sourceUrl: 'https://other.example/', requestType: 'document'),
          'script-src none');
      expect(
          engine.cspFor('https://x.example/',
              sourceUrl: 'https://masked.example/', requestType: 'document'),
          isNull);
      expect(
          engine.shouldBlock('https://y.example/a.js',
              sourceUrl: 'https://other.example/', requestType: 'script'),
          isTrue);
      expect(
          engine.shouldBlock('https://y.example/a.js',
              sourceUrl: 'https://masked.example/', requestType: 'script'),
          isFalse);
    }, skip: libExists ? false : skipReason);

    test('a rule scoped to the masked site itself is excepted there', () {
      final engine = AdblockEngine.load('${scope('masked.example##.ad')}\n')!;
      addTearDown(engine.dispose);
      final resources = engine.cosmeticResources('https://masked.example/');
      expect((resources?['hide_selectors'] as List?), isEmpty);
      expect((resources?['exceptions'] as List?)?.cast<String>(),
          contains('.ad'));
    }, skip: libExists ? false : skipReason);

    test('merging into an existing negation keeps both exclusions', () {
      final engine = AdblockEngine.load(
          '${scope(r'||ads.example^$domain=~news.example')}\n')!;
      addTearDown(engine.dispose);
      for (final source in ['news.example', 'masked.example']) {
        expect(
          engine.shouldBlock('https://ads.example/x',
              sourceUrl: 'https://$source/', requestType: 'script'),
          isFalse,
          reason: '$source must stay excluded',
        );
      }
      expect(
        engine.shouldBlock('https://ads.example/x',
            sourceUrl: 'https://other.example/', requestType: 'script'),
        isTrue,
      );
    }, skip: libExists ? false : skipReason);

    test('an unmasked list is unaffected by another list being masked', () {
      final engine = AdblockEngine.load(
          '${scope('||ads.example^')}\n||other.example^\n')!;
      addTearDown(engine.dispose);
      expect(
        engine.shouldBlock('https://other.example/x.js',
            sourceUrl: 'https://masked.example/', requestType: 'script'),
        isTrue,
      );
    }, skip: libExists ? false : skipReason);
  });
}

bool _libraryExists() {
  final cwd = Directory.current.path;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File(
          '$cwd/rust/webspace_adblock/target/release/libwebspace_adblock.$ext')
      .existsSync();
}
