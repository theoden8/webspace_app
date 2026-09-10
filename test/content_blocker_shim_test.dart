import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/content_blocker_shim.dart';

/// Pure-Dart string-shape assertions for the content-blocker shim
/// builders. The behavioural side (jsdom + computed style) lives in
/// test/js/content_blocker_shim*.test.js — this file is the cheap
/// guardrail against shapes that would silently break injection.
void main() {
  group('buildContentBlockerEarlyCssShim', () {
    test('returns null when nothing to inject', () {
      expect(
          buildContentBlockerEarlyCssShim(selectors: const []), isNull);
    });

    test('emits one display:none rule per selector', () {
      final js = buildContentBlockerEarlyCssShim(
          selectors: ['.ad', 'div.banner'])!;
      expect(js, contains('.ad { display: none !important; }'));
      expect(js, contains('div.banner { display: none !important; }'));
    });

    test('emits :style() declarations instead of display:none', () {
      // The whole point of :style() is that the rule applies *custom*
      // declarations, not display:none. If both ended up emitted the
      // CSS-engine cascade would still hide the element (display:none
      // wins), defeating uBO `:style()` entirely.
      final js = buildContentBlockerEarlyCssShim(
        selectors: const [],
        styleRules: const [
          (selector: '.banner', declarations: 'height: 1px !important'),
        ],
      )!;
      expect(js, contains('.banner { height: 1px !important }'));
      expect(js, isNot(contains('display: none')),
          reason: ':style() rules must NOT emit display:none');
    });

    test('mixes selectors and :style() rules in one <style> tag', () {
      final js = buildContentBlockerEarlyCssShim(
        selectors: const ['.ad'],
        styleRules: const [
          (selector: '.banner', declarations: 'visibility: hidden'),
        ],
      )!;
      expect(js, contains('.ad { display: none !important; }'));
      expect(js, contains('.banner { visibility: hidden }'));
    });

    test('a filter list cannot break out of the CSS string literal', () {
      // The blob is a JS string literal, and its contents come from a
      // downloaded filter list. A quote must survive as data, and so must a
      // newline: the payload is one script of concatenated shims, so a single
      // SyntaxError here silences every shim after it.
      final js = buildContentBlockerEarlyCssShim(
        selectors: const [],
        styleRules: const [
          (selector: '.x', declarations: "content: 'ad'"),
          (selector: '.y', declarations: 'color: red;\n} body { display: none'),
        ],
      )!;
      // The blob is emitted as a JSON literal, so a quote is data and needs no
      // escape; a newline is escaped rather than ending the literal.
      expect(js, contains("content: 'ad'"));
      expect(js, isNot(contains('red;\n}')),
          reason: 'a raw newline would terminate the string literal');
      expect(js, contains(r'red;\n}'));
    });
  });

  group('buildContentBlockerCosmeticShim', () {
    test('returns null when selectors, styles, and text rules are empty', () {
      expect(
          buildContentBlockerCosmeticShim(
              selectors: const [], textRules: const []),
          isNull);
    });

    test('emits style rules even when no display:none selectors apply', () {
      // The `<style>` tag's job extends past `display:none` — a page
      // with only `:style()` rules still needs the early CSS shim
      // (and the cosmetic shim, on re-injection) to fire.
      final js = buildContentBlockerCosmeticShim(
        selectors: const [],
        textRules: const [],
        styleRules: const [
          (selector: '.banner', declarations: 'opacity: 0'),
        ],
      );
      expect(js, isNotNull);
      expect(js!, contains('.banner { opacity: 0 }'));
    });

    test('keeps MutationObserver gated behind a non-empty TEXT_RULES', () {
      // Observer installation is gated on TEXT_RULES.length > 0 —
      // the selector path is owned entirely by the early <style> tag,
      // so when no text rules apply the observer must never run.
      // Misgating this would re-introduce the per-mutation JS work
      // the 2026 perf fix was specifically designed to remove.
      final js = buildContentBlockerCosmeticShim(
        selectors: const ['.ad'],
        textRules: const [],
      )!;
      expect(js, contains('var TEXT_RULES = []'),
          reason: 'empty text rules must surface as empty array');
      expect(js, contains('if (TEXT_RULES.length > 0)'),
          reason: 'observer must be runtime-gated, not unconditional');
    });

    test('installs MutationObserver when text rules present', () {
      final js = buildContentBlockerCosmeticShim(
        selectors: const [],
        textRules: const [
          (selector: 'p.notice', patterns: ['Sponsored']),
        ],
      )!;
      expect(js, contains('MutationObserver'));
      expect(js, contains('hideText'));
      expect(js, contains('"Sponsored"'));
    });
  });
}
