// Phase 1 spike: prove the Rust-backed adblock engine loads, parses
// rules, and answers block decisions through the FFI binding. This
// test runs against the Linux-native release build at
// `rust/webspace_adblock/target/release/libwebspace_adblock.so`,
// which `tool/build_rust.sh` (or a manual `cargo build --release`)
// produces.
//
// Skipped automatically when the library is not present — that's
// the right behavior on CI machines that haven't built the Rust
// crate yet.

@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/adblock_engine.dart';

void main() {
  // Determine availability up-front. Skipping at the group level
  // keeps the report clean — without this, every test would mark
  // itself "ok" or fail with NPE on the engine reference.
  final libExists = _libraryExists();

  group('AdblockEngine (Rust-backed FFI)', () {
    test('library is present at expected path', () {
      expect(libExists, isTrue,
          reason:
              'libwebspace_adblock not built yet. Run: '
              '`cd rust/webspace_adblock && cargo build --release`');
    }, skip: libExists ? false : 'library not built');

    test('loads + parses + reports a version', () {
      final e = AdblockEngine.load('||example.com^\n');
      expect(e, isNotNull);
      expect(e!.version, contains('webspace_adblock'),
          reason: 'version string should identify our wrapper crate');
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('blocks a simple ||domain^ rule', () {
      final e = AdblockEngine.load('||tracker.com^\n')!;
      expect(
        e.shouldBlock('https://tracker.com/x',
            sourceUrl: 'https://news.com/'),
        isTrue,
      );
      expect(
        e.shouldBlock('https://other.com/x',
            sourceUrl: 'https://news.com/'),
        isFalse,
      );
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('honors path-anchored rules', () {
      final e = AdblockEngine.load('||example.com/ads/\n')!;
      expect(
        e.shouldBlock('https://example.com/ads/banner.png',
            sourceUrl: 'https://news.com/'),
        isTrue,
      );
      expect(
        e.shouldBlock('https://example.com/news/',
            sourceUrl: 'https://news.com/'),
        isFalse,
      );
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('honors \$domain= modifier — the headline reason for adopting this engine', () {
      // This is the rule shape our hand-rolled parser drops entirely,
      // and the rule shape that prompted the engine swap. A real
      // engine handles it for free.
      final e = AdblockEngine.load('||tracker.com^\$domain=news.com\n')!;
      expect(
        e.shouldBlock('https://tracker.com/x',
            sourceUrl: 'https://news.com/article'),
        isTrue,
        reason: 'rule should fire when source domain is news.com',
      );
      expect(
        e.shouldBlock('https://tracker.com/x',
            sourceUrl: 'https://blog.com/article'),
        isFalse,
        reason: 'rule should NOT fire on other domains',
      );
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('honors @@ exception rules', () {
      final e = AdblockEngine.load('||tracker.com^\n@@||cdn.tracker.com^\n')!;
      expect(
        e.shouldBlock('https://tracker.com/x',
            sourceUrl: 'https://news.com/'),
        isTrue,
      );
      expect(
        e.shouldBlock('https://cdn.tracker.com/x',
            sourceUrl: 'https://news.com/'),
        isFalse,
      );
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('returns domain-scoped cosmetic selectors', () {
      // Generic ##.x rules go through hidden_class_id_selectors,
      // not url_cosmetic_resources — they need a separate
      // scan-and-query API that isn't wired up yet. Domain-scoped
      // rules surface here directly.
      final e = AdblockEngine.load('example.com##.feed-promo\n')!;
      final res = e.cosmeticResources('https://example.com/');
      expect(res, isNotNull);
      final hides = res!['hide_selectors'];
      expect(hides, isA<List>());
      expect(hides.cast<String>(), contains('.feed-promo'));
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('returns generic selectors targeting page classes/ids', () {
      // Generic ##.x rules don't appear in cosmeticResources(url)'s
      // hide_selectors — they go through hiddenClassIdSelectors,
      // gated on the page actually using a class/id the rule targets.
      final e = AdblockEngine.load('##.ad-banner\n##.unrelated\n##.foo:has(.bar)\n')!;
      final selectors = e.hiddenClassIdSelectors({'ad-banner', 'foo'}, {});
      expect(selectors, contains('.ad-banner'),
          reason: 'engine must return rules targeting classes the page lists');
      expect(selectors, isNot(contains('.unrelated')),
          reason: 'rules targeting unused classes must not appear');
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('hiddenClassIdSelectors returns empty when nothing matches', () {
      final e = AdblockEngine.load('##.ad-banner\n')!;
      final selectors = e.hiddenClassIdSelectors({'completely-different'}, {});
      expect(selectors, isEmpty);
      e.dispose();
    }, skip: libExists ? false : 'library not built');

    test('content-blocking export emits WKContentRuleList-shaped JSON', () {
      // The Pod hook will pipe this JSON into
      // `WKContentRuleListStore.compileContentRuleList` at install
      // time. Asserting the shape (array of {action, trigger}
      // objects) matches what Apple's API expects keeps the iOS
      // integration honest without needing a real WebKit instance
      // to test against.
      final json = AdblockEngine.filterListToAppleContentBlockingJson(
        '||doubleclick.net^\n||tracker.com^\$third-party\n##.ad-banner\n',
      );
      expect(json, isNotNull,
          reason: 'export must succeed with the library loaded');
      expect(json!.startsWith('['), isTrue,
          reason: 'Apple format is a JSON array of rules');
      expect(json, contains('"action"'));
      expect(json, contains('"trigger"'));
      expect(json, contains('doubleclick'),
          reason: 'concrete rule must surface in the exported JSON');
    }, skip: libExists ? false : 'library not built');

    test('rewrittenUrl strips \$removeparam= keys', () {
      // Global $removeparam rule (no host scope) — applies wherever
      // the URL has the targeted query key. Same shape uBO ships in
      // EasyList/AdGuard "URL Tracking Protection" lists.
      final e = AdblockEngine.load(r'*$removeparam=utm_source');
      try {
        // Matching param → rewrite returns the URL without the
        // stripped key, with other params preserved.
        //
        // requestType='document' is load-bearing: adblock-rust gates
        // $removeparam= application on resource type (document /
        // subdocument / xhr). The default 'other' returns None for
        // queryless or untargeted URLs, which would mask the real
        // miss case below.
        final out = e!.rewrittenUrl(
            'https://tracker.example.com/x?utm_source=fb&keep=1',
            requestType: 'document');
        expect(out, isNotNull,
            reason: 'engine should produce a rewrite when the param matches');
        expect(out!, isNot(contains('utm_source')),
            reason: 'utm_source must be gone after rewrite');
        expect(out, contains('keep=1'),
            reason: 'non-targeted params must survive');

        // No query string: nothing to rewrite.
        expect(
            e.rewrittenUrl('https://example.org/x', requestType: 'document'),
            isNull,
            reason: 'queryless URL must not produce a rewrite');

        // Query without the targeted key: also no rewrite.
        expect(
            e.rewrittenUrl('https://example.org/x?keep=1',
                requestType: 'document'),
            isNull,
            reason: 'URL without the targeted param must not be rewritten');
      } finally {
        e?.dispose();
      }
    }, skip: libExists ? false : 'library not built');

    test('cspFor returns directives for \$csp= rules', () {
      final e = AdblockEngine.load(
          r"||cspy.example^$csp=script-src 'none'");
      try {
        final csp = e!.cspFor('https://cspy.example/page',
            sourceUrl: '', requestType: 'document');
        expect(csp, isNotNull,
            reason: 'engine should surface CSP for a matching rule');
        expect(csp!, contains("script-src"),
            reason: 'directives string must include the rule\'s policy');

        expect(e.cspFor('https://other.example/page', requestType: 'document'),
            isNull,
            reason: 'unrelated host must not produce CSP');
      } finally {
        e?.dispose();
      }
    }, skip: libExists ? false : 'library not built');

    test('serialize / loadFromSerialized round-trips an engine', () {
      final src = AdblockEngine.load(
          '||doubleclick.net^\n||googlesyndication.com^');
      try {
        final blob = src!.serialize();
        expect(blob, isNotNull, reason: 'serialize must succeed');
        expect(blob!.isNotEmpty, isTrue,
            reason: 'serialized blob should be non-empty');

        final rehydrated = AdblockEngine.loadFromSerialized(blob);
        try {
          expect(rehydrated, isNotNull,
              reason: 'deserialize must accept its own output');
          // Rules should behave identically.
          expect(rehydrated!.shouldBlock('https://doubleclick.net/x'),
              isTrue);
          expect(rehydrated.shouldBlock('https://example.org/x'), isFalse);
        } finally {
          rehydrated?.dispose();
        }
      } finally {
        src?.dispose();
      }
    }, skip: libExists ? false : 'library not built');

    test('parses a real curated EasyList sample without panicking', () {
      // Same fixture the existing parser-based test consumes. The
      // engine accepts every rule shape in it, including the ones
      // our Dart parser deliberately skips (`#$#`, `##^`, regex,
      // `$csp`, `$removeparam`). No assertions on result count —
      // just that loading doesn't fail.
      final text = File('test/fixtures/easylist_sample.txt')
          .readAsStringSync();
      final e = AdblockEngine.load(text);
      expect(e, isNotNull, reason: 'engine should accept the curated sample');
      e!.dispose();
    }, skip: libExists ? false : 'library not built');
  });
}

bool _libraryExists() {
  final cwd = Directory.current.path;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File(
          '$cwd/rust/webspace_adblock/target/release/libwebspace_adblock.$ext')
      .existsSync();
}
