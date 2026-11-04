// ESLint over every script the app runs in a page, as it is injected: parts
// included and the CONFIG wrapper applied. A part linted on its own would
// report every name it borrows from the script that includes it, so there is
// no eslint.config.js for editors to apply to lib/js file by file; this is the
// lint. The payload of the worker shim is one script of concatenated IIFEs, so
// a ReferenceError in one silences every shim after it: `no-undef` is why
// this exists.

const test = require('node:test');
const assert = require('node:assert/strict');
const { pageEslint: eslint } = require('./helpers/page_eslint');
const { SAMPLES } = require('./helpers/page_js_samples');

for (const [name, source] of Object.entries(SAMPLES)) {
  // SHIM-TEST-003
  test(`${name}.js passes ESLint as injected`, async () => {
    const [result] = await eslint.lintText(source, { filePath: `${name}.js` });
    const lines = source.split('\n');
    const problems = result.messages.map((m) =>
      `${m.ruleId}: ${m.message} — ${(lines[m.line - 1] || '').trim()}`);
    assert.deepEqual(problems, []);
  });
}
