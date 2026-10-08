import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/content_blocker_shim.dart';

/// What the content-blocker builders hand the page. The stylesheet those
/// configs build, and what it hides, is tested in
/// test/js/content_blocker_shim*.test.js.
void main() {
  group('buildContentBlockerEarlyCssShim', () {
    test('returns null when nothing to inject', () {
      expect(
          buildContentBlockerEarlyCssShim(selectors: const []), isNull);
    });

    test('hands the page its selectors and :style() rules as data', () {
      final js = buildContentBlockerEarlyCssShim(
        selectors: const ['.ad'],
        styleRules: const [
          (selector: '.banner', declarations: 'visibility: hidden'),
        ],
      )!;
      expect(js, contains('"selectors":[".ad"]'));
      expect(
          js,
          contains('"styleRules":[{"selector":".banner",'
              '"declarations":"visibility: hidden"}]'));
    });

    test('a filter list cannot break out of its literal', () {
      // The contents come from a downloaded filter list. A quote must survive
      // as data, and so must a newline: the payload is one script of
      // concatenated shims, so a single SyntaxError here silences every shim
      // after it.
      final js = buildContentBlockerEarlyCssShim(
        selectors: const [],
        styleRules: const [
          (selector: '.x', declarations: "content: 'ad'"),
          (selector: '.y', declarations: 'color: red;\n} body { display: none'),
        ],
      )!;
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

    test('a page with only :style() rules still gets the shim', () {
      expect(
          buildContentBlockerCosmeticShim(
            selectors: const [],
            textRules: const [],
            styleRules: const [
              (selector: '.banner', declarations: 'opacity: 0'),
            ],
          ),
          isNotNull);
    });

    test('hands the page its text rules as data', () {
      final js = buildContentBlockerCosmeticShim(
        selectors: const [],
        textRules: const [
          (selector: 'p.notice', patterns: ['Sponsored']),
        ],
      )!;
      expect(js, contains('"textRules":[{"sel":"p.notice","pats":["Sponsored"]}]'));
    });
  });
}
