// The ESLint a script the app puts in a page is held to: a classic script in
// a page or a worker, with the rules a shim keeps. test/js/page_js_lint.test.js
// lints the scripts in lib/js with it, test/js/redirect_scripts.test.js the
// redirect scripts the adblock library serves.

const { ESLint } = require('eslint');
const js = require('@eslint/js');
const globals = require('globals');
const { REPO } = require('./source');

const pageEslint = new ESLint({
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

module.exports = { pageEslint };
