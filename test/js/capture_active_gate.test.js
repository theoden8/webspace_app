// Backgrounded-site gate wiring (CAM-011 / MIC-011 / SHARE-011).
//
// The engines take `isSiteActive` as a REQUIRED argument, so the compiler
// already forces every call site to pass something. What it cannot force is
// that the something is real: `isSiteActive: () => true` compiles, satisfies
// every engine test, and silently reopens the hole the requirement exists to
// close — a background site prompting under the visible site's name.
//
// A structural gate because the failure is invisible at runtime in tests: the
// suite is green either way, and the symptom only appears with two sites
// loaded and one of them off screen.
//
// This also covers `InAppWebViewScreen`, whose predicate is `mounted` and
// which no unit test can reach without mounting a platform view.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');

const SOURCES = ['lib/web_view_model.dart', 'lib/screens/inappbrowser.dart'];

// The argument text after `isSiteActive:`, up to the comma that ends it at
// bracket depth 0.
function argumentsAt(src) {
  const found = [];
  const needle = 'isSiteActive:';
  let from = 0;
  for (;;) {
    const at = src.indexOf(needle, from);
    if (at === -1) break;
    let depth = 0;
    let i = at + needle.length;
    let arg = '';
    for (; i < src.length; i++) {
      const c = src[i];
      if (c === '(' || c === '[' || c === '{') depth++;
      else if (c === ')' || c === ']' || c === '}') {
        if (depth === 0) break; // end of the enclosing argument list
        depth--;
      } else if (c === ',' && depth === 0) break;
      arg += c;
    }
    found.push({ arg: arg.trim(), line: src.slice(0, at).split('\n').length });
    from = at + needle.length;
  }
  return found;
}

const sites = [];
for (const rel of SOURCES) {
  const src = code(read(rel));
  for (const s of argumentsAt(src)) sites.push({ ...s, rel });
}

test('the known isSiteActive call sites are present', () => {
  // Three capture resolvers on the model, three on the nested screen, plus the
  // navigation engine's. A drop to zero would make this file vacuous.
  assert.ok(sites.length >= 8,
    `expected the known isSiteActive call sites, found ${sites.length}`);
});

for (const { rel, line, arg } of sites) {
  test(`${rel}:${line}: isSiteActive is not a constant`, () => {
    const normalized = arg.replace(/\s+/g, '');
    assert.ok(
      !['true', 'false', '()=>true', '()=>false'].includes(normalized),
      `a hard-coded "${arg}" reopens CAM-011 / MIC-011 / SHARE-011: a `
        + `backgrounded site ` +
        `would prompt under the visible site's name. Pass the host's real ` +
        `activity predicate (isActive / mounted).`,
    );
    assert.match(
      arg,
      /isActive|mounted/,
      `isSiteActive must derive from the host's activity state, got "${arg}"`,
    );
  });
}
