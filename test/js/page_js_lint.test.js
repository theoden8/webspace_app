// ESLint over every script the app runs in a page, as it is injected: parts
// included and the CONFIG wrapper applied. A part linted on its own would
// report every name it borrows from the script that includes it, so there is
// no eslint.config.js for editors to apply to lib/js file by file; this is the
// lint. The payload of the worker shim is one script of concatenated IIFEs, so
// a ReferenceError in one silences every shim after it: `no-undef` is why
// this exists.

const test = require('node:test');
const assert = require('node:assert/strict');
const { ESLint } = require('eslint');
const js = require('@eslint/js');
const globals = require('globals');
const { REPO } = require('./helpers/source');
const { SAMPLES } = require('./helpers/page_js_samples');

const eslint = new ESLint({
  cwd: REPO,
  overrideConfigFile: true,
  overrideConfig: [
    js.configs.recommended,
    {
      languageOptions: {
        ecmaVersion: 'latest',
        sourceType: 'script',
        // Page and worker: the worker shim's payload runs in both.
        globals: { ...globals.browser, ...globals.worker },
      },
      // A directive in a part answers for one script that includes it and is
      // unused in another.
      linterOptions: { reportUnusedDisableDirectives: 'off' },
      rules: {
        // A shim swallows errors at the page's API on purpose: a throw would
        // reach the page, or stop the shims injected after it.
        'no-empty': ['error', { allowEmptyCatch: true }],
        // Wrappers keep the platform's parameter list and catch binding.
        'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
        // An error thrown to the page must look like the engine's own, and
        // those carry no `cause`.
        'preserve-caught-error': 'off',
      },
    },
  ],
});

for (const [name, source] of Object.entries(SAMPLES)) {
  test(`${name}.js passes ESLint as injected`, async () => {
    const [result] = await eslint.lintText(source, { filePath: `${name}.js` });
    const lines = source.split('\n');
    const problems = result.messages.map((m) =>
      `${m.ruleId}: ${m.message} — ${(lines[m.line - 1] || '').trim()}`);
    assert.deepEqual(problems, []);
  });
}
