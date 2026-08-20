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
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const openspecRoot = path.join(repoRoot, 'openspec');

function markdownFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...markdownFiles(full));
    else if (entry.name.endsWith('.md')) out.push(full);
  }
  return out;
}

test('OpenSpec cross-document links all resolve', () => {
  const dangling = [];
  let checked = 0;
  for (const file of markdownFiles(openspecRoot)) {
    const source = fs.readFileSync(file, 'utf8');
    // Document-to-document links only. Links from a spec into source files
    // are a separate, wider problem: several use the wrong depth and a few
    // name files that no longer exist. Widening this guard to cover them
    // means fixing those first, in a change of their own -- an allowlist
    // here would just enshrine the rot.
    for (const match of source.matchAll(/\]\((\.\.?\/[^)\s#]+\.md)(?:#[^)\s]*)?\)/g)) {
      checked += 1;
      const target = path.resolve(path.dirname(file), match[1]);
      if (!fs.existsSync(target)) {
        dangling.push(`${path.relative(repoRoot, file)} -> ${match[1]}`);
      }
    }
  }
  assert.ok(checked > 50, `expected many links, found ${checked} — extraction broke?`);
  assert.deepEqual(dangling, [],
    'Dangling OpenSpec links. Point each at where the requirement actually '
    + 'lives; a feature whose change is not archived yet is under '
    + 'openspec/changes/<slug>/specs/<slug>/spec.md, not openspec/specs/.');
});
