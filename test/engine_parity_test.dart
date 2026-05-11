// Side-by-side parity tests for the two ABP engines this codebase
// supports:
//
//   * **Legacy Dart parser** — `parseAbpFilterListSync` + the
//     aggregated `_blockedDomains` / `_cosmeticSelectors` hot path
//     in `ContentBlockerService`. The canonical engine when the
//     `useRustAdblockEngine` toggle is off.
//   * **Rust adblock-rust** — `AdblockEngine` via FFI. The optional
//     engine when the toggle is on.
//
// The goal here is NOT to test each engine's correctness in
// isolation (those tests live in `abp_filter_parser_test.dart` /
// `adblock_engine_test.dart` respectively). The goal is to assert
// that for the rule shapes both engines claim to support, they
// produce the SAME block decision on the same URL. And for shapes
// only the engine supports, to pin the expected divergence so we
// notice if the Dart parser starts (incorrectly) firing them, or
// the engine stops firing them.
//
// Skipped automatically when the Rust .so isn't built — same
// gating contract as the other engine-touching tests.

@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/abp_filter_parser.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/host_lookup.dart';

/// Verdict produced by either engine.
typedef _Verdict = ({bool blocked, String engine});

bool _libraryExists() {
  final cwd = Directory.current.path;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File(
          '$cwd/rust/webspace_adblock/target/release/libwebspace_adblock.$ext')
      .existsSync();
}

void main() {
  final libExists = _libraryExists();
  if (!libExists) {
    test('engine parity tests skipped (Rust library not built)', () {
      expect(libExists, isTrue,
          reason: 'cd rust/webspace_adblock && cargo build --release');
    }, skip: 'Rust library not built');
    return;
  }

  /// Decision from the Dart parser-based engine: replay
  /// `ContentBlockerService.isBlocked`'s logic against a
  /// pre-parsed rule set.
  bool legacyBlocks(AbpParseResult parsed, String url) {
    final host = extractHost(url);
    if (host == null || host.isEmpty) return false;
    if (parsed.exceptionDomains.isNotEmpty &&
        hostInSet(host, parsed.exceptionDomains)) {
      return false;
    }
    if (hostInSet(host, parsed.blockedDomains)) return true;
    // Path-anchored walk-up — the parser stores raw globs; mirror
    // the service's compile-on-rebuild step inline so the test
    // doesn't drag in ContentBlockerService.
    String domain = host;
    while (domain.isNotEmpty) {
      final paths = parsed.blockedDomainPaths[domain];
      if (paths != null) {
        final pathPart = extractPathAndQuery(url);
        for (final rule in paths) {
          if (compileDomainPathGlob(rule.pathGlob).hasMatch(pathPart)) {
            return true;
          }
        }
      }
      final dotIdx = domain.indexOf('.');
      if (dotIdx < 0) break;
      domain = domain.substring(dotIdx + 1);
    }
    return false;
  }

  group('Engine parity — shapes both engines must agree on', () {
    late AdblockEngine engine;
    late AbpParseResult parsed;

    setUp(() {
      const rules = '''
||tracker.example.com^
||ads.example.com/banners/
@@||cdn.tracker.example.com^
##.ad-banner
example.com##.feed-promo
''';
      parsed = parseAbpFilterListSync(rules);
      engine = AdblockEngine.load(rules)!;
    });

    tearDown(() => engine.dispose());

    void expectAgrees(String url, {String? source}) {
      final legacy = legacyBlocks(parsed, url);
      final engineDecision = engine.shouldBlock(
        url,
        sourceUrl: source ?? '',
        requestType: 'other',
      );
      expect(
        engineDecision,
        equals(legacy),
        reason: 'Engines disagree on $url'
            '${source != null ? " (source: $source)" : ""}'
            ': legacy=$legacy, engine=$engineDecision',
      );
    }

    test(r'||tracker.example.com^ — simple host block matches', () {
      expectAgrees('https://tracker.example.com/x',
          source: 'https://news.com/');
      expectAgrees('https://sub.tracker.example.com/x',
          source: 'https://news.com/');
    });

    test('non-blocked host — both engines allow', () {
      expectAgrees('https://other.com/x', source: 'https://news.com/');
      expectAgrees('https://example.com/foo', source: 'https://news.com/');
    });

    test('path-anchored block matches', () {
      expectAgrees('https://ads.example.com/banners/banner.png',
          source: 'https://news.com/');
    });

    test('path-anchored allow (outside glob) matches', () {
      expectAgrees('https://ads.example.com/news/article.html',
          source: 'https://news.com/');
    });

    test('@@ exception suppresses the rule consistently', () {
      expectAgrees('https://cdn.tracker.example.com/resource.js',
          source: 'https://news.com/');
    });

    test('case-insensitive host matching — legacy lowercases, engine quirk documented', () {
      // Legacy parser lowercases hosts before lookup, so an uppercase
      // URL still matches. The engine treats the URL bytes as-is. In
      // production every URL handed to either path is already
      // lowercase (WebView's `controller.getUrl()` and chromium's
      // `shouldInterceptRequest` both normalise), so the divergence
      // is purely API-boundary. Documenting it so a future engine
      // bump that flips this behaviour will fail the test.
      expect(
        legacyBlocks(parsed, 'HTTPS://TRACKER.EXAMPLE.COM/x'),
        isTrue,
        reason: 'legacy parser case-folds hosts',
      );
      expect(
        engine.shouldBlock('HTTPS://TRACKER.EXAMPLE.COM/x',
            sourceUrl: 'https://news.com/'),
        isFalse,
        reason:
            'engine treats URLs as-is; production URLs are always lowercase',
      );
      // Lowercased: both agree.
      expectAgrees('https://tracker.example.com/x',
          source: 'https://news.com/');
    });

    test('non-http schemes both allow', () {
      expectAgrees('about:blank');
      expectAgrees('data:text/html,hi');
    });
  });

  group('Engine parity — engine refines decisions the legacy parser over-blocks',
      () {
    // Shapes where the Dart parser strips the modifier and falls
    // back to a coarse host-block, while the engine handles the
    // modifier properly. This is the "engine is more accurate" axis:
    // legacy fires the rule on every request (over-block); engine
    // fires only when the modifier's conditions hold.
    //
    // The tests pin BOTH sides: if legacy starts respecting the
    // modifier (e.g. someone extends the parser), we want to know.
    // If engine stops respecting it (upstream bump), we want to know.
    late AdblockEngine engine;
    late AbpParseResult parsed;

    setUp(() {
      const rules = r'''
||tracker.example.com^$domain=news.com
/^https?:\/\/regex-blocked\.example\//
||script-only.example.com^$script
''';
      parsed = parseAbpFilterListSync(rules);
      engine = AdblockEngine.load(rules)!;
    });

    tearDown(() => engine.dispose());

    test(r'$domain= rule: legacy host-promotes; engine respects the modifier',
        () {
      // legacy: parser strips `$domain=news.com`, leaving `||tracker.
      // example.com^` which gets added to blockedDomains. Result:
      // legacy fires for ANY referrer (over-block).
      expect(legacyBlocks(parsed, 'https://tracker.example.com/x'), isTrue,
          reason:
              r'legacy parser strips $domain= and host-blocks (documented over-block)');

      // engine: respects the modifier — fires only when source is news.com.
      expect(
        engine.shouldBlock('https://tracker.example.com/x',
            sourceUrl: 'https://news.com/article'),
        isTrue,
      );
      expect(
        engine.shouldBlock('https://tracker.example.com/x',
            sourceUrl: 'https://blog.com/article'),
        isFalse,
        reason: 'engine must NOT fire on off-list referrer',
      );

      // Net divergence on `blog.com` source: legacy=true, engine=false.
      // The engine is correct; legacy is over-blocking.
    });

    test('regex rule: engine fires, legacy drops', () {
      // `/regex/`-style rules ARE recognised by the parser's
      // `pattern.startsWith('/') && pattern.endsWith('/')` skip,
      // unlike $-modifier rules above — so this is a true "engine
      // fires, legacy doesn't" case.
      expect(legacyBlocks(parsed, 'https://regex-blocked.example/path'),
          isFalse,
          reason: 'Dart parser must not parse /regex/ rules');
      expect(
        engine.shouldBlock('https://regex-blocked.example/path',
            sourceUrl: 'https://news.com/'),
        isTrue,
      );
    });

    test(r'$script rule: legacy host-promotes; engine respects requestType',
        () {
      // Same pattern as $domain= — parser strips `$script` and the
      // residual `||script-only.example.com^` becomes a coarse host
      // block. Legacy fires on every resource type.
      expect(
        legacyBlocks(parsed, 'https://script-only.example.com/banner.png'),
        isTrue,
        reason:
            r'legacy parser strips $script and host-blocks all resource types (documented over-block)',
      );

      // engine: respects resource type.
      expect(
        engine.shouldBlock('https://script-only.example.com/a.js',
            sourceUrl: 'https://news.com/', requestType: 'script'),
        isTrue,
        reason: 'engine fires on script requests',
      );
      expect(
        engine.shouldBlock('https://script-only.example.com/banner.png',
            sourceUrl: 'https://news.com/', requestType: 'image'),
        isFalse,
        reason: r'engine must NOT fire on image requests for $script rule',
      );
    });
  });

  group('Engine parity — curated EasyList sample', () {
    // Real-shaped rules from test/fixtures/easylist_sample.txt fed
    // to both engines. For URLs targeting shapes both engines
    // support, the decisions must match. This catches the case
    // where parser/engine versions drift on what "supported"
    // means.
    late AdblockEngine engine;
    late AbpParseResult parsed;

    setUp(() {
      final rules =
          File('test/fixtures/easylist_sample.txt').readAsStringSync();
      parsed = parseAbpFilterListSync(rules);
      engine = AdblockEngine.load(rules)!;
    });

    tearDown(() => engine.dispose());

    // URL battery covering rule shapes the sample exercises.
    const sharedShapeCases = <(String, bool, String)>[
      ('https://doubleclick.net/x', true, 'simple host block'),
      ('https://sub.doubleclick.net/x', true, 'subdomain via walk-up'),
      ('https://googlesyndication.com/x', true, 'second host block'),
      ('https://cdn.googlesyndication.com/x', false, '@@ exception'),
      ('https://pathblock.example/ads/banner.png', true, 'path-anchored'),
      ('https://pathblock.example/news/index.html', false,
          'path-anchored allow'),
      ('https://example.com/foo', false, 'unrelated host'),
      ('https://en.wikipedia.org/wiki/Foo', false, 'control wiki'),
    ];

    for (final (url, expectedBlocked, label) in sharedShapeCases) {
      test('curated sample: $label — $url', () {
        final legacy = legacyBlocks(parsed, url);
        final engineDecision = engine.shouldBlock(
          url,
          sourceUrl: 'https://news.com/article',
          requestType: 'other',
        );
        expect(legacy, equals(expectedBlocked),
            reason: 'Dart parser ($label)');
        expect(engineDecision, equals(expectedBlocked),
            reason: 'Engine ($label)');
        expect(engineDecision, equals(legacy),
            reason: 'Engines diverged on $label');
      });
    }
  });
}
