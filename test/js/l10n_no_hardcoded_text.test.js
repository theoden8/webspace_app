// Localization invariant LOC-002, ported from the former Dart
// test/l10n_no_hardcoded_text_test.dart so it runs in the Node checks job. A
// UI file must never pass a raw string literal into a user-facing display
// sink; every readable string goes through AppLocalizations.
//
// Every Dart file under the scanned roots is enforced, so a new screen is
// covered without an edit here. `exempt` names files not yet routed through
// AppLocalizations; it only shrinks.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, exists, dartFiles, code, lineAt } = require('./helpers/source');

const exempt = new Set([]);

const scanned = ['lib/main.dart', 'lib/app.dart', ...dartFiles('lib/screens'), ...dartFiles('lib/widgets')];

// Display sinks that put a string directly on screen. A quoted literal
// opening immediately inside any of these is unkeyed text.
const sinkPatterns = [
  /\b(?:Text|SelectableText|Tooltip)\(\s*(?:const\s+)?['"]/g,
  /\b(?:tooltip|hintText|labelText|helperText|errorText|counterText|prefixText|suffixText|semanticLabel)\s*:\s*['"]/g,
];

function findHardcodedDisplayText(rel, source) {
  const stripped = code(source);
  const hits = [];
  for (const p of sinkPatterns) {
    for (const m of stripped.matchAll(p)) {
      const line = lineAt(stripped, m.index);
      const snippet = stripped.slice(m.index, m.index + 60).split('\n')[0].trim();
      hits.push(`  ${rel}:${line}: ${snippet}`);
    }
  }
  hits.sort();
  return hits;
}

test('exempt files still exist', () => {
  assert.deepEqual([...exempt].filter((f) => !exists(f)), [],
    'Exempt file(s) no longer exist; drop them from `exempt`.');
});

test('UI files contain no hardcoded user-facing text', () => {
  const violations = scanned
    .filter((rel) => !exempt.has(rel))
    .flatMap((rel) => findHardcodedDisplayText(rel, read(rel)));
  assert.deepEqual(
    violations,
    [],
    `Hardcoded user-facing string(s) found. Route each through AppLocalizations:\n${violations.join('\n')}`,
  );
});
