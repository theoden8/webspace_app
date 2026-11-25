// US-009: the page side of a script's header. Dart compiles the patterns
// (test/userscript_match_test.dart holds the grammar); the gate tests them
// against the document's URL as the script is about to run. An exclusion
// wins, a header naming no page lets every page run, and a regex the page's
// engine rejects names no page. The planted mistake below is the gate with
// one fault, and must fail a row.

const test = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const { pageJs, pageJsSource } = require('./helpers/page_js');

const p = (source, flags = '') => ({ source, flags });

/** The gate's answer for [config] in a document at [url]. */
function gate(url, config, source = pageJs('userscript_gate', config)) {
  const dom = new JSDOM('<!doctype html><p>', { url, runScripts: 'outside-only' });
  return dom.window.eval(source);
}

const watch = {
  include: [p('^https://(?:[^/?#:]+\\.)?example\\.com(?::\\d+)?/watch.*$')],
  exclude: [p('^https://(?:[^/?#:]+\\.)?example\\.com(?::\\d+)?/watch/private.*$')],
};

const rows = [
  { why: 'an included page runs', config: watch, url: 'https://www.example.com/watch?v=1', runs: true },
  { why: 'another page of the site does not', config: watch, url: 'https://www.example.com/feed', runs: false },
  { why: 'an exclusion wins over an inclusion', config: watch, url: 'https://example.com/watch/private/1', runs: false },
  { why: 'a header naming no page runs everywhere', config: { include: null, exclude: [] }, url: 'https://any.example/', runs: true },
  { why: 'an exclusion applies to every page too', config: { include: null, exclude: [p('^https://any\\.example/x.*$')] }, url: 'https://any.example/x1', runs: false },
  { why: 'patterns that were all invalid name no page', config: { include: [], exclude: [] }, url: 'https://any.example/', runs: false },
  { why: 'a flag reaches the engine', config: { include: [p('^HTTPS://ANY\\.EXAMPLE/$', 'i')], exclude: [] }, url: 'https://any.example/', runs: true },
  { why: 'a regex the engine rejects names no page', config: { include: [p('(?<=a)(?<'), p('^https://any\\.example/$')], exclude: [p('(')] }, url: 'https://any.example/', runs: true },
  { why: 'a rejected regex alone names no page', config: { include: [p('(')], exclude: [] }, url: 'https://any.example/', runs: false },
];

for (const row of rows) {
  test(`US-009: ${row.why}`, () => {
    assert.equal(gate(row.url, row.config), row.runs);
  });
}

test('US-009: an error other than a rejected regex is not swallowed', () => {
  assert.throws(() => gate('https://any.example/', { include: [null], exclude: [] }));
});

/** Planted mistakes: the gate's text with one fault each. */
const planted = {
  'gate ignores exclude': pageJsSource('userscript_gate').replace(
    '!CONFIG.exclude.some(names)', 'true'),
};

for (const [mistake, body] of Object.entries(planted)) {
  test(`US-009: the rows catch the planted mistake: ${mistake}`, () => {
    assert.notEqual(body, pageJsSource('userscript_gate'), 'the mistake still applies');
    const failing = rows.filter((row) => {
      const source = `(function (CONFIG) {\n${body}\n})(${JSON.stringify(row.config)});\n`;
      return gate(row.url, row.config, source) !== row.runs;
    });
    assert.ok(failing.length > 0);
  });
}
