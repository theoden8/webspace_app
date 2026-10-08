// Gate for the scripts the app runs in pages (CLAUDE.md, Style).
//
// Every one lives in lib/js/ and reaches Dart through PageJs
// (lib/services/page_js.dart), which a type enforces from there on. What no
// type can say: that a Dart string literal is not JavaScript, that a script
// parses, and that this tier reads lib/js the way PageJs does. Those are
// checked here, over source text.

const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { read, dartFiles, jsFiles, code } = require('./helpers/source');
const { INCLUDE, pageJs, pageJsSource } = require('./helpers/page_js');
const { SAMPLES } = require('./helpers/page_js_samples');

const entries = jsFiles()
  .map((rel) => rel.slice('lib/js/'.length, -'.js'.length))
  .filter((name) => !name.startsWith('_'));

test('the scan sees the scripts (self-check)', () => {
  assert.ok(entries.length > 30, `only ${entries.length} scripts found`);
  assert.ok(entries.includes('do_not_track'));
});

for (const name of entries) {
  test(`${name}.js parses as the app injects it`, () => {
    const source = pageJsSource(name);
    const js = /\bCONFIG\./.test(source) ? pageJs(name, {}) : source;
    assert.doesNotThrow(() => new vm.Script(js, { filename: `${name}.js` }));
  });
}

test('every script has a sample the all-scripts gates run', () => {
  assert.deepEqual(Object.keys(SAMPLES).sort(), [...entries].sort(),
    'add the script to helpers/page_js_samples.js with a realistic config');
});

test('this tier reads lib/js the way PageJs does', () => {
  const dart = read('lib/services/page_js.dart');
  assert.ok(dart.includes(String.raw`r'^[ \t]*// @include (\S+)[ \t]*$'`),
    'the include line PageJs resolves changed; change INCLUDE in helpers/page_js.js too');
  assert.equal(INCLUDE.source, String.raw`^[ \t]*\/\/ @include (\S+)[ \t]*$`);
  assert.ok(dart.includes(
    "'(function (CONFIG) {\\n$_source\\n})(${jsonEncode(config)});\\n'"),
    'the CONFIG wrapper PageJs builds changed; change pageJs() in helpers/page_js.js too');
  assert.equal(pageJs('language', { language: 'en' }).split('\n')[0], '(function (CONFIG) {');
});

// A multi-line string literal in a Dart file under lib/ that reads like a
// script: two or more of these tokens.
const JS_TOKENS = /\b(function|var |let |const |window\.|document\.|navigator\.|globalThis\.|=>)/g;
const LITERAL = /(?:r?)('''|""")([\s\S]*?)\1/g;

test('no page script is written as a Dart string', () => {
  const inline = [];
  for (const rel of dartFiles('lib')) {
    const src = code(read(rel));
    const raw = read(rel);
    for (const m of raw.matchAll(LITERAL)) {
      // Skip a literal that sits inside a comment (blanked by code()).
      if (src.slice(m.index, m.index + 3) !== raw.slice(m.index, m.index + 3)) continue;
      if ((m[2].match(JS_TOKENS) || []).length >= 2) {
        inline.push(`${rel}:${raw.slice(0, m.index).split('\n').length}`);
      }
    }
  }
  assert.deepEqual(inline, [],
    'move the script to lib/js/ and read it through PageJs; a value goes in '
      + 'through withConfig');
});
