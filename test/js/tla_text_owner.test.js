// Structural gate: the scripts under formal/ take a TLA+ module's comments out
// through formal/tla_text.py alone.
//
// Three scripts each had their own reading: footprint.py's regex did not nest
// block comments, so `(* a (* b *) c *)` left ` c *)` as code, while
// world_key.py and proofs/integrity.py nested them. A script naming TLA+'s
// comment delimiters itself is that second reading, and what this refuses
// (rung 5: a Python script has no type for "TLA+ text").

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, lineAt } = require('./helpers/source');

const OWNER = 'formal/tla_text.py';
// The delimiters in a string literal or a regex: "(*", '*)', r"\(\*", "\\*".
const DELIMITER = /["'](?:\(\*|\*\)|\\\(\\\*|\\\\\*)/g;

function readsComments(rel, src) {
  return [...src.matchAll(DELIMITER)].map((m) => `${rel}:${lineAt(src, m.index)}`);
}

test('only tla_text.py reads TLA+ comments', () => {
  const found = files('formal', /\.py$/)
    .filter((rel) => rel !== OWNER)
    .flatMap((rel) => readsComments(rel, read(rel)));
  assert.deepEqual(found, [], 'call tla_text.code(text, keep_strings=...)');
  assert.ok(readsComments(OWNER, read(OWNER)).length > 0, `${OWNER} reads them`);
});

test('planted: a script stripping comments itself is caught', () => {
  for (const planted of [
    'text = re.sub(r"\\(\\*.*?\\*\\)", " ", text, flags=re.S)\n',
    'if text.startswith("(*", i):\n',
    "elif two == '\\\\*':\n",
  ]) {
    assert.equal(readsComments('planted.py', planted).length, 1, planted);
  }
  assert.deepEqual(readsComments('planted.py', 'set().union(*sets.values())\n'), []);
});
