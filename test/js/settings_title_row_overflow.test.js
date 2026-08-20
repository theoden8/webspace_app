// A ListTile title of `Row([Text, HintButton])` overflows on the right as soon
// as the title text needs more room than the row has - narrow windows, long
// translations, large text scales. The fix is always the same: let the label
// flex so it wraps instead of overflowing. This gate keeps the pattern from
// creeping back one tile at a time.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const scanRoots = ['lib/main.dart', 'lib/screens', 'lib/widgets'];

// How far past `children: [` we still consider ourselves inside the same row.
const ROW_WINDOW = 600;

function discoverDartFiles(roots) {
  const out = [];
  const walk = (abs, rel) => {
    for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
      const childAbs = path.join(abs, e.name);
      const childRel = `${rel}/${e.name}`;
      if (e.isDirectory()) walk(childAbs, childRel);
      else if (e.isFile() && e.name.endsWith('.dart')) out.push(childRel);
    }
  };
  for (const root of roots) {
    const abs = path.join(repoRoot, root);
    if (!fs.existsSync(abs)) continue;
    if (fs.statSync(abs).isDirectory()) walk(abs, root);
    else if (root.endsWith('.dart')) out.push(root);
  }
  return out;
}

function findRigidTitles(rel, source) {
  const hits = [];
  const opener = /children:\s*\[\s*\n\s*(\w+)\(/g;
  for (const m of source.matchAll(opener)) {
    if (m[1] !== 'Text' && m[1] !== 'SelectableText') continue;
    const row = source.slice(m.index, m.index + ROW_WINDOW);
    if (!row.includes('HintButton(')) continue;
    const line = (source.slice(0, m.index).match(/\n/g) || []).length + 1;
    hits.push(`  ${rel}:${line}: ${m[1]}( sits next to a HintButton unflexed`);
  }
  return hits;
}

test('a label sharing a row with a HintButton can flex', () => {
  const violations = [];
  for (const rel of discoverDartFiles(scanRoots)) {
    const abs = path.join(repoRoot, rel);
    violations.push(...findRigidTitles(rel, fs.readFileSync(abs, 'utf8')));
  }
  assert.deepEqual(
    violations,
    [],
    'Wrap each label in Flexible(child: ...) so it wraps instead of '
      + `overflowing the row:\n${violations.join('\n')}`,
  );
});
