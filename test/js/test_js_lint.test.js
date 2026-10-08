// ESLint over the Node tests with the repo's eslint.config.js: the run CI sees
// of what an editor shows file by file. test/js/page_js_lint.test.js lints the
// page scripts.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { ESLint } = require('eslint');
const { REPO } = require('./helpers/source');

const eslint = new ESLint({ cwd: REPO });

test('the Node tests pass ESLint', async () => {
  const results = await eslint.lintFiles(['test/js', 'test/browser']);
  assert.ok(results.length > 100, `linted only ${results.length} files`);
  const problems = results.flatMap((r) => r.messages.map((m) =>
    `${path.relative(REPO, r.filePath)}:${m.line} ${m.ruleId}: ${m.message}`));
  assert.deepEqual(problems, []);
});

test('a script in a template is reported; a page, a sample and a message are not', async () => {
  const rules = async (text) => {
    const [result] = await eslint.lintText(text,
      { filePath: path.join(REPO, 'test/js/probe.test.js') });
    return result.messages.map((m) => m.ruleId);
  };
  const script = 'const S = `\n  window.x = 1;\n  document.title = "y";\n`;\nmodule.exports = S;\n';
  const body = 'const S = `\n  if (!window.x) return;\n  window.x();\n`;\nmodule.exports = S;\n';
  const html = 'const S = `<!doctype html>\n<script>window.x = 1;</script>\n`;\nmodule.exports = S;\n';
  const dart = 'const S = `\nclass S {\n  Future<bool> f(String url) async => true;\n}`;\nmodule.exports = S;\n';
  const message = 'const S = (a) => `expected one, got\n${a}`;\nmodule.exports = S;\n';
  assert.deepEqual(await rules(script), ['local/no-script-template']);
  assert.deepEqual(await rules(body), ['local/no-script-template']);
  assert.deepEqual(await rules(html), []);
  assert.deepEqual(await rules(dart), []);
  assert.deepEqual(await rules(message), []);
});
