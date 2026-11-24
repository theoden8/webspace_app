// Structural gate over the CI workflow: every run block parses under the
// shell that runs it, and the plan job's guards hold.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const YAML = require('yaml');
const { read } = require('./helpers/source');

const WORKFLOW = '.github/workflows/build-and-test.yml';


/** A job's block: its header line up to the next job's. */
function job(text, id) {
  const start = text.indexOf(`\n  ${id}:\n`);
  assert.notEqual(start, -1, `${id} job not found`);
  const rest = text.slice(start + 1);
  const next = rest.search(/\n {2}[a-z][a-z-]*:\n/);
  return next === -1 ? rest : rest.slice(0, next);
}

// Which shell runs a step: its own `shell`, else the job's or the workflow's
// default, else what GitHub picks, `sh` (dash) inside a container job and
// `bash` on the runner. A bash-only form in an `sh` step, such as a
// here-string, is a syntax error only when the step runs (BUG-034), so each
// block is parsed by the shell that will run it.
function stepShell(workflow, job, step) {
  const shell = step.shell ?? job.defaults?.run?.shell ?? workflow.defaults?.run?.shell
      ?? (job.container ? 'sh' : 'bash');
  return shell.split(/\s+/)[0];
}

function hasDash() {
  try {
    execFileSync('dash', ['-c', ':'], { stdio: 'pipe' });
    return true;
  } catch (e) {
    if (e.code === 'ENOENT') return false;
    throw e;
  }
}

test('every run block parses under the shell that runs it', (t) => {
  if (!hasDash()) {
    if (process.env.CI === 'true') assert.fail('dash is needed to parse the sh steps');
    t.skip('no dash on PATH');
    return;
  }
  const parser = { sh: 'dash', bash: 'bash' };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wf-run-'));
  const failures = [];
  let parsed = 0;
  try {
    for (const source of [WORKFLOW]) {
      const workflow = YAML.parse(read(source));
      const jobs = workflow.jobs ?? { composite: { steps: workflow.runs.steps } };
      let sourceParsed = 0;
      for (const [jobName, job] of Object.entries(jobs)) {
        for (const [i, step] of (job.steps ?? []).entries()) {
          if (typeof step.run !== 'string') continue;
          const shell = stepShell(workflow, job, step);
          if (!parser[shell]) continue;
          const file = path.join(dir, `${jobName}-${i}.sh`);
          fs.writeFileSync(file, step.run.replace(/\$\{\{[^}]*\}\}/g, 'X'));
          try {
            execFileSync(parser[shell], ['-n', file], { stdio: 'pipe' });
          } catch (e) {
            failures.push(`${source} / ${jobName} / ${step.name ?? `step ${i}`} (${shell}): `
                + `${e.stderr?.toString().trim()}`);
          }
          parsed++;
          sourceParsed++;
        }
      }
      assert.ok(sourceParsed > 0, `no run blocks parsed in ${source}`);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  assert.ok(parsed > 10, `parsed only ${parsed} run blocks; has the workflow changed shape?`);
  assert.deepEqual(failures, []);
});

// The `[ci-only: ...]` marker exists so a bisection that reads one tier does
// not pay for the other two. Its failure modes are asymmetric: a job that
// wrongly runs costs runner minutes, a job that wrongly skips costs coverage
// silently, and a marker left in a merged commit could silence master
// forever. So the guardrails are gated rather than trusted.
test('every heavy job is gated on the plan job', () => {
  const text = read(WORKFLOW);
  for (const [job, output] of [
    ['build-android', 'android'],
    ['build-linux', 'linux'],
    ['build-apple', 'apple'],
    ['screenshots-android', 'screenshots'],
    ['screenshots-ios', 'screenshots'],
    ['screenshots-macos', 'screenshots'],
    ['screenshots-linux', 'screenshots'],
  ]) {
    const block = YAML.parse(text).jobs[job];
    assert.ok(
      [block.needs].flat().includes('plan'),
      `${job} does not depend on the plan job, so its guard cannot be read`,
    );
    assert.match(
      block.if,
      new RegExp(`needs\\.plan\\.outputs\\.${output} === ?'true'`.replace('===', '==')),
      `${job} is not gated on needs.plan.outputs.${output}`,
    );
  }
});

test('the ci-only marker is honoured on pull requests only', () => {
  const text = read(WORKFLOW);
  const plan = text.slice(text.indexOf('\n  plan:\n'), text.indexOf('\n  build-android:\n'));
  assert.match(
    plan,
    /if \[ "\$\{\{ github\.event_name \}\}" = pull_request \]; then/,
    'the plan job reads the marker outside a pull_request guard; a marker ' +
      'that survives a merge would then silence master',
  );
  assert.match(
    plan,
    /ci-only/,
    'the plan job no longer parses a ci-only marker',
  );
  // Comma-delimited matching, so `apple` cannot be enabled by `pineapple`.
  assert.match(
    plan,
    /case ",\$only," in/,
    'token matching is not comma-delimited, so one token can enable another',
  );
});

// A release cannot go green without its store screenshots (docs/releasing.md),
// so which runs make them is decided once, by the plan job, from the event and
// the version line. A step gated on the event by hand would skip the release
// PR and nothing would fail: YAML has no type for "this step makes a
// screenshot".
test('screenshots run on a manual run and on a release PR, decided by plan', () => {
  const text = read(WORKFLOW);
  assert.ok(
    !/\n\s+if: github\.event_name == 'workflow_dispatch'/.test(text),
    "a step is gated on workflow_dispatch by hand; gate it on needs.plan.outputs.screenshots == 'true'",
  );
  const start = text.indexOf('\n  plan:\n');
  const plan = text.slice(start, text.indexOf('\n  build-android:\n'));
  assert.match(plan, /\n {6}screenshots: \$\{\{ steps\.screenshots\.outputs\.screenshots \}\}\n/);
  assert.match(plan, /sed -n 's\/\^version: \/\/p' pubspec\.yaml/,
    'the plan job no longer reads the version line, so a release PR would skip the screenshots');
  assert.match(plan, /\*,screenshots,\*\) screenshots=true/,
    'a ci-only marker naming screenshots no longer runs them');
  assert.match(plan,
    /elif \[ "\$\{\{ inputs\.screenshots_only \}\}" = true \]; then\n\s+only=screenshots\n/,
    'the screenshots_only input is no longer the [ci-only: screenshots] marker');
});

// A device's set is a job of its own so a screenshots-only run takes them all
// at once, and the merge job is what makes them one download. A set whose job
// the merge does not wait for is uploaded after the merge ran and is missing
// from it, with every job green.
test('every device feeds the one screenshots artifact', () => {
  const text = read(WORKFLOW);
  const merge = job(text, 'screenshots');
  assert.match(merge, /pattern: '\*-screenshots'/);
  const needs = merge.match(/\n {4}needs: \[([^\]]*)\]/)[1].split(',').map((n) => n.trim());
  for (const id of ['screenshots-android', 'screenshots-ios', 'screenshots-macos', 'screenshots-linux']) {
    assert.ok(needs.includes(id), `the screenshots merge does not wait for ${id}`);
    assert.match(job(text, id), /\n +name: [^\n]*-screenshots\n/,
      `${id} uploads no *-screenshots artifact for the merge to take`);
  }
  const ios = job(text, 'screenshots-ios');
  for (const device of ['iphone', 'ipad']) {
    assert.match(ios, new RegExp(`\\n +- device: ${device}\\n`),
      `the iOS screenshot matrix has no ${device}`);
  }
  assert.match(ios, /name: \$\{\{ matrix\.device \}\}-screenshots\n/);
  assert.match(ios, /name: \$\{\{ matrix\.device \}\}-framed-screenshots\n/,
    'the iOS framed sets no longer reach the merge');
});

// Some lock files are written only on one platform: Podfile.lock by the pod
// install every job on the Apple toolchain runs, Gemfile.lock by a bundle
// install that is not frozen. The lockfiles job lays what each job hands in
// over the commit and publishes every lock file as one artifact. A job that
// writes one and hands nothing in, or that the merge does not wait for, drops
// it with every job green.
test('every job that writes a lock file feeds the one lockfiles artifact', () => {
  const { jobs } = YAML.parse(read(WORKFLOW));
  const handIn = (j) => (j.steps ?? []).find((s) => s.uses === './.github/actions/lockfiles');
  const writes = (j) => (j.steps ?? []).some((s) => s.uses === './.github/actions/apple-toolchain'
    || /\bbundle install\b/.test(s.run ?? ''));
  const writers = Object.keys(jobs).filter((id) => writes(jobs[id]));
  assert.ok(writers.includes('build-apple'), 'no job writing a lock file was found');
  for (const id of writers) {
    const step = handIn(jobs[id]);
    assert.ok(step, `${id} writes a lock file and does not hand it in`);
    assert.equal(step.if, 'success() || failure()',
      `${id} hands nothing in when its build fails, which is when a lock file is wanted`);
    if (jobs[id].strategy?.matrix) {
      assert.match(step.with?.name ?? '', /\$\{\{ matrix\./,
        `${id}'s legs hand in under one name, and the second upload fails`);
    }
  }
  const needs = [jobs.lockfiles.needs].flat();
  for (const [id, j] of Object.entries(jobs)) {
    if (handIn(j)) assert.ok(needs.includes(id), `the lockfiles merge does not wait for ${id}`);
  }
  assert.equal(jobs.lockfiles.if, '${{ !cancelled() }}',
    'the lockfiles job skips when a build fails, which is when a lock file is wanted');
});
