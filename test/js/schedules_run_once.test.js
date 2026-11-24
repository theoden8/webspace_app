// Structural gate: formal/verify.sh's schedules stage runs exactly the test
// files tagged `schedules`. A file tagged that the stage does not name runs
// nowhere, and one the stage names without the tag runs twice.
//
// Rung 5: which stage runs which test file is shell, which no type sees.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, code } = require('./helpers/source');

const TAG = 'schedules';

/** The test files carrying `@Tags([...])` with `tag` among them. */
function tagged(sources, tag) {
  return Object.entries(sources)
    .filter(([, src]) => {
      const m = /@Tags\(\s*\[([^\]]*)\]\s*\)/.exec(code(src));
      return m && m[1].split(',').some((t) => t.trim().replace(/^'|'$/g, '') === tag);
    })
    .map(([file]) => file)
    .sort();
}

/** The test files the schedules stage of formal/verify.sh runs. */
function stageFiles(verify) {
  const start = verify.indexOf('\nschedules() {');
  assert.notEqual(start, -1, 'formal/verify.sh has no schedules() stage');
  const body = verify.slice(start, verify.indexOf('\n}', start));
  return [...new Set(body.match(/test\/[\w/]+_test\.dart/g) ?? [])].sort();
}

const testSources = Object.fromEntries(
  files('test', /_test\.dart$/).map((f) => [f, read(f)]),
);

test('the schedules stage runs exactly the files tagged schedules', () => {
  const inStage = stageFiles(read('formal/verify.sh'));
  assert.ok(inStage.length > 0, 'the schedules stage names no test file');
  assert.deepEqual(tagged(testSources, TAG), inStage);
});

test('the gate sees what it guards', () => {
  assert.deepEqual(tagged({
    'a_test.dart': "@Tags(['schedules'])\nlibrary;\n",
    'b_test.dart': "@Tags(['ci', 'schedules'])\nlibrary;\n",
    'c_test.dart': "@Tags(['ci'])\nlibrary;\n",
    'd_test.dart': "// @Tags(['schedules'])\nvoid main() {}\n",
  }, TAG), ['a_test.dart', 'b_test.dart']);
  assert.deepEqual(
    stageFiles('x\nschedules() {\n  $FLUTTER test test/a_test.dart\n}\ny() {\n  test/b_test.dart\n}\n'),
    ['test/a_test.dart']);
});
