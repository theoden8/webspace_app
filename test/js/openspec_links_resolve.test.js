// Every relative link between OpenSpec documents must resolve.
//
// A spec that cites another spec's requirement id is the only thing tying the
// two together; `openspec validate` checks each document's own structure and
// says nothing about cross-references, so a link can rot silently. It did:
// INTEG-012 pointed at openspec/specs/web-push-notifications/spec.md, which
// has never existed, because that feature is implemented but its change was
// never archived and its requirements still live under openspec/changes/.
//
// Reading a dangling link as "these requirements do not exist anywhere" is the
// expensive failure mode, and it is what this guard exists to prevent.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { read, exists, files } = require('./helpers/source');

test('OpenSpec cross-document links all resolve', () => {
  const dangling = [];
  let checked = 0;
  for (const file of files('openspec', /\.md$/)) {
    const source = read(file);
    // Document-to-document links only. Links from a spec into source files
    // are a separate, wider problem: several use the wrong depth and a few
    // name files that no longer exist. Widening this guard to cover them
    // means fixing those first, in a change of their own -- an allowlist
    // here would just enshrine the rot.
    for (const match of source.matchAll(/\]\((\.\.?\/[^)\s#]+\.md)(?:#[^)\s]*)?\)/g)) {
      checked += 1;
      if (!exists(path.join(path.dirname(file), match[1]))) {
        dangling.push(`${file} -> ${match[1]}`);
      }
    }
  }
  assert.ok(checked > 50, `expected many links, found ${checked} — extraction broke?`);
  assert.deepEqual(dangling, [],
    'Dangling OpenSpec links. Point each at where the requirement actually '
    + 'lives; a feature whose change is not archived yet is under '
    + 'openspec/changes/<slug>/specs/<slug>/spec.md, not openspec/specs/.');
});
