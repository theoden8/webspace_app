// Structural gate: a gate lists the files it reads through helpers/source.js
// (`files`, `dartFiles`, `dartFilesUnder`).
//
// Two gates walked their directories by hand, and two more read only the top
// level, so a widget in lib/widgets/<dir>/ or a Runner file in a subfolder
// was never checked. A hand-written directory walk in a gate is what this
// refuses (rung 5: nothing types a path list).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, code, lineAt } = require('./helpers/source');

const WALK = /\breaddirSync\s*\((?:[^()]|\([^()]*\))*withFileTypes/g;

function walks(rel, src) {
  const text = code(src, { strings: true });
  return [...code(src).matchAll(WALK)]
    .filter((m) => text[m.index] === 'r')
    .map((m) => `${rel}:${lineAt(src, m.index)}`);
}

test('no gate walks a directory itself', () => {
  const found = files('test', /\.test\.js$/)
    .flatMap((rel) => walks(rel, read(rel)));
  assert.deepEqual(found, [], 'list the files with files(dir, re) or dartFilesUnder(roots)');
});

test('planted: a hand-written walk is caught, one in a comment is not', () => {
  assert.deepEqual(walks('planted.js', 'fs.readdirSync(abs, { withFileTypes: true });\n'),
    ['planted.js:1']);
  assert.deepEqual(
    walks('planted.js', 'fs.readdirSync(path.join(dir, rel), { withFileTypes: true });\n'),
    ['planted.js:1']);
  assert.deepEqual(walks('planted.js', '// fs.readdirSync(abs, { withFileTypes: true })\n'), []);
});
