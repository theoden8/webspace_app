// ESLint for the Node tests, which editors and `npx eslint` apply file by file
// and test/js/test_js_lint.test.js runs in CI. The scripts in lib/js are not
// here: a part linted on its own reports every name it borrows from the script
// that includes it, so test/js/page_js_lint.test.js lints them as injected.

const js = require('@eslint/js');
const globals = require('globals');
const noScriptTemplate = require('./test/js/helpers/no_script_template');

const TESTS = ['test/js/**/*.js', 'test/browser/**/*.js'];

module.exports = [
  // Everything else is out of scope, so `npx eslint .` means the tests.
  { ignores: ['**/*.js', '**/*.mjs', '**/*.cjs', ...TESTS.map((glob) => `!${glob}`)] },
  { files: TESTS, ...js.configs.recommended },
  {
    files: TESTS,
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'commonjs',
      // Node, plus the page and worker realms a test hands its functions to.
      globals: { ...globals.node, ...globals.browser, ...globals.worker },
    },
    linterOptions: { reportUnusedDisableDirectives: 'error' },
    plugins: { local: { rules: { 'no-script-template': noScriptTemplate } } },
    rules: {
      'local/no-script-template': 'error',
      // Teardown that may find the thing already gone.
      'no-empty': ['error', { allowEmptyCatch: true }],
      // Handlers keep the signature their caller passes.
      'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
    },
  },
];
