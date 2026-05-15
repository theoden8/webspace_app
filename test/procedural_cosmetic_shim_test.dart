// Pure-Dart tests for the procedural cosmetic shim builder. Asserts
// the JS output contains the expected handlers for the operator/action
// shapes adblock-rust hands us. The shim's actual page-side behaviour
// (running operators against a DOM) is exercised by the jsdom layer
// in test/js/procedural_cosmetic_shim.test.js — this file only
// guards the Dart builder against silent regressions.

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/procedural_cosmetic_shim.dart';

void main() {
  group('buildProceduralCosmeticShim', () {
    test('returns null for empty input', () {
      expect(buildProceduralCosmeticShim(const []), isNull);
    });

    test('returns null when all inputs fail JSON parse', () {
      expect(
        buildProceduralCosmeticShim(['not-json', '{']),
        isNull,
      );
    });

    test('embeds the rule list as a JS string literal', () {
      final shim = buildProceduralCosmeticShim([
        '{"selector":[{"type":"css-selector","arg":".feed"},'
            '{"type":"has-text","arg":"Sponsored"}],"action":"remove"}',
      ]);
      expect(shim, isNotNull);
      // Engine's procedural_actions are pre-JSON; we encode the parsed
      // list back to JSON and embed in the shim. Spot-check the
      // selector + action both made it through.
      expect(shim, contains('"css-selector"'));
      expect(shim, contains('Sponsored'));
      expect(shim, contains('"remove"'));
    });

    test('handles all five operator types in the runner', () {
      final shim = buildProceduralCosmeticShim([
        '{"selector":[{"type":"css-selector","arg":".x"}],"action":"remove"}'
      ])!;
      // The runner must branch on each operator type adblock-rust
      // surfaces. The branches we DO handle:
      for (final op in [
        'css-selector',
        'has-text',
        'upward',
        'min-text-length',
        'matches-path',
      ]) {
        expect(shim, contains("'$op'"),
            reason: 'operator $op branch must exist in applyOp()');
      }
    });

    test('handles all four action types in the runner', () {
      final shim = buildProceduralCosmeticShim([
        '{"selector":[{"type":"css-selector","arg":".x"}]}'
      ])!;
      // Default action = hide (no `action` key). Explicit actions:
      expect(shim, contains("'remove'"),
          reason: 'remove action branch must exist in applyAction()');
      expect(shim, contains("'style'"),
          reason: 'style action branch must exist');
      expect(shim, contains("'remove-attr'"),
          reason: 'remove-attr action branch must exist');
      expect(shim, contains("'remove-class'"),
          reason: 'remove-class action branch must exist');
    });

    test('installs a MutationObserver for SPA updates', () {
      final shim = buildProceduralCosmeticShim([
        '{"selector":[{"type":"css-selector","arg":".x"}]}'
      ])!;
      expect(shim, contains('MutationObserver'));
      expect(shim, contains('childList'));
      expect(shim, contains('subtree'));
    });

    test('escapes single quotes in rule JSON to keep the literal valid', () {
      // A has-text with an apostrophe would break the JS string if
      // not escaped. (We aren't building that input here — the
      // engine wouldn't normally emit it — but the escape is the
      // shim's invariant and worth pinning.)
      final shim = buildProceduralCosmeticShim([
        "{\"selector\":[{\"type\":\"has-text\",\"arg\":\"can't\"}]}",
      ])!;
      // The embedded literal should not contain an unescaped ' that
      // would terminate JSON.parse('...').
      // The shim wraps with JSON.parse('<escaped>') — count single
      // quotes outside the JS source structure.
      expect(shim, contains("can\\'t"),
          reason: 'apostrophe in arg must be backslash-escaped for JS string');
    });
  });
}
