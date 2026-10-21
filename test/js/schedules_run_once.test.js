// Structural gate: CI runs the schedule search once, in the formal job.
//
// test/activation_schedules_test.dart is most of the suite's time: on the
// macOS runner it was 33 of the unit step's 45 minutes on one core, after
// every other file had finished. formal/verify.sh's schedules stage already
// runs it, sharded, and it reads no host platform, so the whole-suite runs
// leave it out by its tag. That holds only while the two lists agree: a file
// tagged `schedules` that the stage does not name runs nowhere, and one the
// stage names without the tag runs twice.
//
// Rung 5: which job runs which test file is YAML and shell, which no type
// sees.

const test = require('node:test');
const assert = require('node:assert/strict');
const YAML = require('yaml');
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

/**
 * The `flutter test` commands in a workflow's run steps that take the whole
 * suite: no file named. A folded or continued command is read whole.
 */
function wholeSuiteRuns(workflow) {
  const runs = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    for (const step of job.steps ?? []) {
      if (typeof step.run !== 'string') continue;
      for (const line of step.run.replace(/\\\n\s*/g, ' ').split('\n')) {
        const cmd = line.trim();
        if (cmd.startsWith('#') || !/(^|\s)fvm flutter test(\s|$)/.test(cmd)) continue;
        if (/\S+_test\.dart|\$t\b|\$file\b|-d (macos|linux)/.test(cmd)) continue;
        runs.push({ where: `${jobName} / ${step.name ?? 'step'}`, cmd });
      }
    }
  }
  return runs;
}

const testSources = Object.fromEntries(
  files('test', /_test\.dart$/).map((f) => [f, read(f)]),
);

test('the schedules stage runs exactly the files tagged schedules', () => {
  const inStage = stageFiles(read('formal/verify.sh'));
  assert.ok(inStage.length > 0, 'the schedules stage names no test file');
  assert.deepEqual(tagged(testSources, TAG), inStage);
});

test('every whole-suite run in CI excludes the schedules tag', () => {
  const runs = wholeSuiteRuns(YAML.parse(read('.github/workflows/build-and-test.yml')));
  assert.ok(runs.length >= 2, `found ${runs.length} whole-suite runs; has the workflow changed shape?`);
  const missing = runs.filter(({ cmd }) => !cmd.includes(`--exclude-tags ${TAG}`));
  assert.deepEqual(missing.map(({ where, cmd }) => `${where}: ${cmd}`), []);
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
  const step = (run) => ({ name: 'n', run });
  assert.deepEqual(wholeSuiteRuns({ jobs: { j: { steps: [
    step('fvm flutter test'),
    step('fvm flutter test --exclude-tags schedules'),
    step('fvm flutter test --reporter expanded test/a_test.dart'),
    step('fvm flutter test --reporter expanded \\\n  test/a_test.dart'),
    step('fvm flutter test integration_test/tor_test.dart -d macos --ci'),
    step('# fvm flutter test'),
    { uses: 'x' },
  ] } } }).map(({ cmd }) => cmd), [
    'fvm flutter test',
    'fvm flutter test --exclude-tags schedules',
  ]);
});
