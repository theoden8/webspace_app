// Gate for SHIM-TEST-002: a Node test runs the script the webview runs,
// read from lib/js (pageJs, or scriptFunctions for one of its functions),
// never a copy of it.
//
// Rung 5: nothing in a function's type says it is not a page script
// retyped, and the lint (no-script-template) catches only a copy kept in a
// template. Here a run of RUN tokens a test function shares with a script in
// lib/js is a copy, unless the function is listed in KEPT with why it is not
// the script under test; the list only shrinks. Benchmarks (perf/) time an
// old shape against the new one and are no tests.
//
// Planted mistakes: generic_token_prefilter.test.js's own copy of the
// interceptor's urlMaybeGeneric, which this change replaced, made the first
// test fail naming it; so did the copy of fnv1a block_accounting_real_engine
// kept before it read the script's.

const test = require('node:test');
const assert = require('node:assert/strict');
const espree = require('espree');
const { read, files, jsFiles } = require('./helpers/source');
const { pageJsSource } = require('./helpers/page_js');

const RUN = 40;

// Test functions that share code with a page script and are not the script
// under test, each with why.
const KEPT = new Map([
  ['test/js/content_blocker_generic_scanner_fuzz.test.js#rng',
    'mulberry32, the seeded PRNG the fuzz input is drawn from; anti_fingerprinting.js seeds its noise with the same one, and the scanner under test runs from lib/js'],
  ['test/js/helpers/content_blocker_samples.js#cosmeticCssOnly',
    'the CSS-only shape the equivalence tiers run beside the shipped content_blocker_cosmetic.js, never in its place'],
]);

const PARSE = { ecmaVersion: 'latest', range: true };
const tokenOf = (t) => (t.type === 'String' ? `S${t.value.slice(1, -1)}` : t.value);

const scripts = () => jsFiles()
  .map((rel) => rel.slice('lib/js/'.length, -'.js'.length))
  .filter((name) => !name.startsWith('_'));

// Every window of RUN tokens of a script, to the scripts it is in.
function windows() {
  const index = new Map();
  for (const name of scripts()) {
    const tokens = espree.tokenize(pageJsSource(name), PARSE).map(tokenOf);
    for (let i = 0; i + RUN <= tokens.length; i++) {
      const key = tokens.slice(i, i + RUN).join('\u0001');
      index.set(key, (index.get(key) ?? new Set()).add(name));
    }
  }
  return index;
}

const testFiles = (dir) => files(dir, /\.js$/).filter((f) => !f.includes('/perf/'));

// The name of the outermost named function around [offset], or `<top level>`.
function functionAt(ast, offset) {
  let found = null;
  (function visit(node) {
    if (!node || typeof node.type !== 'string') return;
    if (offset < node.range[0] || offset >= node.range[1]) return;
    const own = node.type === 'FunctionDeclaration' ? node.id?.name
      : node.type === 'VariableDeclarator' && node.init && /Function/.test(node.init.type) ? node.id.name
        : (node.type === 'Property' || node.type === 'MethodDefinition') && /Function/.test(node.value?.type) ? node.key.name
          : null;
    if (own && !found) found = own;
    for (const value of Object.values(node)) {
      for (const child of Array.isArray(value) ? value : [value]) {
        if (child && typeof child.type === 'string') visit(child);
      }
    }
  })(ast);
  return found ?? '<top level>';
}

// `file#function` -> the scripts it shares a run of RUN tokens with.
function copies(sources, index = windows()) {
  const out = new Map();
  for (const [file, source] of sources) {
    const ast = espree.parse(source, PARSE);
    const raw = espree.tokenize(source, PARSE);
    const tokens = raw.map(tokenOf);
    for (let i = 0; i + RUN <= tokens.length; i++) {
      const shared = index.get(tokens.slice(i, i + RUN).join('\u0001'));
      if (!shared) continue;
      const key = `${file}#${functionAt(ast, raw[i].range[0])}`;
      out.set(key, new Set([...(out.get(key) ?? []), ...shared]));
    }
  }
  return out;
}

const index = windows();
const found = copies(
  [...testFiles('test/js'), ...testFiles('test/browser')].map((f) => [f, read(f)]),
  index,
);

test('SHIM-TEST-002: no test runs its own copy of a page script', () => {
  const unlisted = [...found]
    .filter(([key]) => !KEPT.has(key))
    .map(([key, scripts]) => `${key} copies ${[...scripts].join(', ')}`);
  assert.deepEqual(unlisted, [],
    'run the script itself: pageJs(name, config), or scriptFunctions(name, { names, given }) for one of its functions');
});

test('SHIM-TEST-002: the kept list only shrinks', () => {
  assert.deepEqual([...KEPT.keys()].filter((key) => !found.has(key)), [],
    'no longer shares code with a page script: drop it from KEPT');
});

test('SHIM-TEST-002: a retyped script function is reported by name; a run of the script is not', () => {
  const copy = [
    "const test = require('node:test');",
    'function urlMaybeGeneric(url, member) {',
    '  var s = url.toLowerCase();',
    '  var n = s.length > 2048 ? 2048 : s.length;',
    '  var start = -1;',
    '  for (var i = 0; i <= n; i++) {',
    '    var c = i < n ? s.charCodeAt(i) : 0;',
    '    var alnum = (c >= 48 && c <= 57) || (c >= 97 && c <= 122);',
    '    if (alnum) {',
    '      if (start < 0) start = i;',
    '    } else {',
    '      if (start >= 0) {',
    '        if (i - start >= 3 && member(s.substring(start, i))) return true;',
    '        start = -1;',
    '      }',
    '    }',
    '  }',
    '  return false;',
    '}',
    "test('x', () => urlMaybeGeneric('https://a.b/c', () => true));",
  ].join('\n');
  const run = [
    "const { scriptFunctions } = require('./helpers/page_js');",
    "const { urlMaybeGeneric } = scriptFunctions('block_js_interceptor', {",
    "  names: ['urlMaybeGeneric'], given: { tokenHit: () => true } });",
  ].join('\n');
  const reported = copies([['test/js/copy.test.js', copy], ['test/js/run.test.js', run]], index);
  assert.deepEqual([...reported.keys()], ['test/js/copy.test.js#urlMaybeGeneric']);
  assert.ok(reported.get('test/js/copy.test.js#urlMaybeGeneric').has('block_js_interceptor'));
});
