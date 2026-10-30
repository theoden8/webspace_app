// GitHub's post-job cache policy and workflow dependencies cannot run in a local shell test.
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const YAML = require('yaml');
const { read } = require('./helpers/source');

const jobs = YAML.parse(read('.github/workflows/formal.yml')).jobs;
const main = YAML.parse(read('.github/workflows/build-and-test.yml'));

// Each stage's cache and the job that keeps it: the TLC shards hand what they
// added to the memo job, which keeps one memo for all four (`work` is the step
// whose outcome says there is something to keep).
const stages = [
  { name: 'models', id: 'formal-cache', keeper: 'memo', work: 'formal-merge' },
  { name: 'steps', id: 'replay-cache', keeper: 'steps', work: 'formal-verify' },
  { name: 'proofs', id: 'tlapm-cache', keeper: 'proofs', work: 'formal-verify' },
];
for (const { name, id, keeper, work } of stages) {
  const job = jobs[name];
  const keep = jobs[keeper];
  const verify = job.steps.find((s) => s.id === 'formal-verify');
  const done = keep.steps.find((s) => s.id === work);
  test(`${name} leaves time to save completed work after a timeout`, () => {
    assert.ok(verify['timeout-minutes'] > 0);
    assert.ok(verify['timeout-minutes'] < (job['timeout-minutes'] ?? 360));
    assert.equal(verify['continue-on-error'] ?? false, false);
  });
  test(`${id} saves completed work after failure and skips restoration in cold mode`, () => {
    const restore = job.steps.find((s) => s.id === id);
    const kept = keep.steps.find((s) => s.id === id);
    const save = keep.steps.find((s) => s.uses === 'actions/cache/save@v4');
    assert.equal(restore.uses, 'actions/cache/restore@v4');
    assert.equal(restore.if, '${{ !inputs.cold }}');
    assert.deepEqual(kept, restore, 'the keeper merges into the memo the stage restored');
    assert.equal(save.with.path, restore.with.path);
    assert.equal(save.with.key, restore.with.key);
    assert.match(save.with.key, /github\.run_id/);
    assert.match(save.with.key, /github\.run_attempt/);
    assert.doesNotMatch(save.with.key, /strategy\./, 'one memo, whichever shard ran a check');
    assert.ok(job.steps.indexOf(restore) < job.steps.indexOf(verify));
    assert.ok(keep.steps.indexOf(kept) < keep.steps.indexOf(done));
    assert.ok(keep.steps.indexOf(save) > keep.steps.indexOf(done));
    const guard = save.if.trim().slice(3, -2).replaceAll(`steps.${work}.outcome`, 'outcome');
    for (const outcome of ['success', 'failure', 'cancelled', 'skipped', '']) {
      assert.equal(vm.runInNewContext(guard, { outcome, always: () => true }),
        ['success', 'failure', 'cancelled'].includes(outcome), outcome);
    }
  });
  test(`${id} falls back to master's newest artifact, which only master's pushes upload`, () => {
    const restore = job.steps.find((s) => s.id === id);
    const upload = keep.steps.find((s) => s.uses === 'actions/upload-artifact@v4' &&
      s.with.path === restore.with.path);
    const dest = restore.with.path.replace(/^~/, '$HOME');
    for (const [where, steps] of new Map([[name, job.steps], [keeper, keep.steps]])) {
      const fallback = steps.find((s) => (s.run ?? '').includes('restore_formal_artifact.sh'));
      assert.equal(fallback.if, `\${{ !inputs.cold && steps.${id}.outputs.cache-matched-key == '' }}`, where);
      assert.equal(fallback.env.GH_TOKEN, '${{ github.token }}', where);
      assert.ok(steps.indexOf(steps.find((s) => s.id === id)) < steps.indexOf(fallback), where);
      assert.ok(fallback.run.trimEnd().split('\n').some((line) =>
        line.includes(`restore_formal_artifact.sh "${upload.with.name}" "${dest}"`) ||
        (line.includes('restore_formal_artifact.sh "$name"') &&
          fallback.run.includes(` ${upload.with.name}; do`))), `${where}: ${fallback.run}`);
    }
    assert.ok(job.steps.indexOf(job.steps.find((s) => (s.run ?? '')
      .includes('restore_formal_artifact.sh'))) < job.steps.indexOf(verify));
    assert.ok(keep.steps.indexOf(upload) > keep.steps.indexOf(done));
    assert.equal(upload.with['include-hidden-files'], true);
    assert.equal(upload.with.overwrite, true);
    const guard = upload.if.trim().slice(3, -2)
      .replaceAll(`steps.${work}.outcome`, 'outcome')
      .replaceAll('github.event_name', 'event').replaceAll('github.ref', 'ref');
    for (const [event, ref] of [['push', 'refs/heads/master'], ['push', 'refs/heads/x'],
      ['pull_request', 'refs/heads/master'], ['workflow_dispatch', 'refs/heads/master']]) {
      for (const outcome of ['success', 'failure', 'cancelled', 'skipped', '']) {
        assert.equal(vm.runInNewContext(guard, { event, ref, outcome, always: () => true }),
          event === 'push' && ref === 'refs/heads/master' &&
            ['success', 'failure', 'cancelled'].includes(outcome), `${event} ${ref} ${outcome}`);
      }
    }
  });
}

test("the formal stages' token may list and download this repository's artifacts", () => {
  assert.deepEqual(main.jobs.formal.permissions, { contents: 'read', actions: 'read' });
});

test('cold model checks and replays cannot use a valid memo or timing history', () => {
  for (const name of ['models', 'steps']) {
    const verify = jobs[name].steps.find((s) => s.id === 'formal-verify');
    assert.equal(verify.env.FORMAL_RERUN, "${{ inputs.cold && '1' || '' }}", name);
    assert.match(verify.run, /rm -rf "\$HOME\/\.cache\/webspace-formal"/, name);
  }
  const proof = jobs.proofs.steps.find((s) => s.id === 'formal-verify');
  assert.match(proof.run, /rm -rf formal\/proofs\/\.tlacache/);
});

test('independent formal stages overlap and the final gate requires all stages', () => {
  assert.equal(jobs.models.needs, 'prepare');
  assert.equal(jobs.proofs.needs, 'prepare');
  assert.equal(jobs.schedules.needs, undefined);
  assert.deepEqual(jobs.steps.needs, ['prepare', 'schedules']);
  assert.deepEqual(jobs.finish.needs, ['prepare', 'models', 'steps', 'proofs']);
  assert.equal(jobs.models.strategy['fail-fast'], false);
  assert.ok(Array.isArray(jobs.models.strategy.matrix.shard),
    'warm and cold runs split alike: a model change misses the memo either way');
  assert.ok(jobs.models.strategy.matrix.shard.length > 1);
  assert.equal(jobs.memo.needs, 'models');
  assert.match(jobs.memo.if, /always\(\)/, 'a failed shard still keeps what it ran');
  assert.equal(jobs.models.steps.find((s) => s.id === 'formal-verify').env.FORMAL_SHARD,
    '${{ strategy.job-index }}/${{ strategy.job-total }}');
  assert.match(jobs.finish.steps[0].run, /all\(\.\[\]; \.result == "success"\)/);
  assert.ok(jobs.finish.steps.some((s) => s.run === './formal/verify.sh --stage finish'));
});

// Bash's stage dispatcher and YAML's jobs cannot share a compile-time enum.
test('the formal workflow runs every driver stage exactly once', () => {
  const stages = [...read('formal/verify.sh').matchAll(/^ {2}([a-z]+)\) /gm)]
    .map((m) => m[1]).filter((s) => s !== 'all').sort();
  const invoked = Object.values(jobs).flatMap((job) => job.steps.flatMap((step) =>
    [...(step.run ?? '').matchAll(/\.\/formal\/verify\.sh --stage ([a-z]+)/g)]
      .map((m) => m[1]))).sort();
  assert.ok(stages.length > 0);
  assert.deepEqual(invoked, stages);
});

test('the required validation status includes sources and the complete formal workflow', () => {
  assert.equal(main.jobs.validate.name, 'Validate Fastlane + OpenSpec + proofs');
  assert.deepEqual(main.jobs.validate.needs, ['plan', 'validate-sources', 'formal']);
  assert.match(main.jobs.validate.steps[0].run, /all\(\.\[\]; \.result == "success"\)/);
  assert.equal(main.jobs.formal.uses, './.github/workflows/formal.yml');
  assert.deepEqual(main.jobs.formal.needs, ['plan', 'validate-sources']);
  assert.match(main.jobs.formal.with.cold, /inputs\.formal_cold/);
  assert.equal(main.on.workflow_dispatch.inputs.formal_cold.type, 'boolean');
});

test('every TLC shard hands the memo job what it added and used, failed or not', () => {
  const steps = jobs.models.steps;
  const verify = steps.find((s) => s.id === 'formal-verify');
  const note = steps.find((s) => (s.run ?? '').includes('memo-before') && !s.if);
  const collect = steps.find((s) => (s.run ?? '').includes('added.tar'));
  const upload = steps.find((s) => s.uses === 'actions/upload-artifact@v4' &&
    s.with.name === 'formal-memo-new-${{ strategy.job-index }}');
  assert.ok(steps.indexOf(note) < steps.indexOf(verify));
  assert.ok(steps.indexOf(collect) > steps.indexOf(verify));
  assert.ok(steps.indexOf(upload) > steps.indexOf(collect));
  assert.equal(collect.if, upload.if);
  assert.match(collect.if, /always\(\)/);
  assert.equal(upload.with.path, '${{ runner.temp }}/memo-new');
  const fetch = jobs.memo.steps.find((s) => s.uses === 'actions/download-artifact@v4');
  assert.equal(fetch.with.pattern, 'formal-memo-new-*');
  assert.equal(fetch.with.path, upload.with.path);
});

// The steps' shell, run on a memo in a temporary home: a shard adds an entry
// and uses an old one, and the merge brings both into a memo restored apart.
test('a merged memo holds what each shard added and keeps what it used', () => {
  const run = (job, pick, env) => {
    const step = jobs[job].steps.find(pick);
    execFileSync('bash', ['-euo', 'pipefail', '-c',
      step.run.replaceAll('${{ inputs.cold }}', 'false')], { env: { ...process.env, ...env } });
  };
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'formal-memo-'));
  const shard = { HOME: path.join(root, 'shard'), RUNNER_TEMP: path.join(root, 'shard-tmp') };
  const keeper = { HOME: path.join(root, 'keeper'), RUNNER_TEMP: path.join(root, 'keeper-tmp') };
  for (const env of [shard, keeper]) {
    fs.mkdirSync(path.join(env.HOME, '.cache/webspace-formal/memo'), { recursive: true });
    fs.mkdirSync(path.join(env.HOME, '.cache/webspace-formal/times'), { recursive: true });
    fs.mkdirSync(env.RUNNER_TEMP, { recursive: true });
  }
  const at = (env, file) => path.join(env.HOME, '.cache/webspace-formal', file);
  const old = new Date(Date.now() - 10 * 86400 * 1000);
  for (const env of [shard, keeper]) {
    fs.writeFileSync(at(env, 'memo/kept'), 'old');
    fs.writeFileSync(at(env, 'memo/idle'), 'old');
    fs.utimesSync(at(env, 'memo/kept'), old, old);
    fs.utimesSync(at(env, 'memo/idle'), old, old);
  }
  run('models', (s) => (s.run ?? '').includes('memo-before') && !s.if, shard);
  fs.writeFileSync(at(shard, 'memo/added'), 'new');
  fs.writeFileSync(at(shard, 'times/added'), '12 4');
  const later = new Date(Date.now() + 1000);
  fs.utimesSync(at(shard, 'memo/added'), later, later);
  fs.utimesSync(at(shard, 'times/added'), later, later);
  fs.utimesSync(at(shard, 'memo/kept'), later, later);
  run('models', (s) => (s.run ?? '').includes('added.tar'), shard);
  fs.cpSync(path.join(shard.RUNNER_TEMP, 'memo-new'),
    path.join(keeper.RUNNER_TEMP, 'memo-new', 'formal-memo-new-0'), { recursive: true });
  run('memo', (s) => s.id === 'formal-merge', keeper);
  assert.equal(fs.readFileSync(at(keeper, 'memo/added'), 'utf8'), 'new');
  assert.equal(fs.readFileSync(at(keeper, 'times/added'), 'utf8'), '12 4');
  assert.ok(fs.statSync(at(keeper, 'memo/kept')).mtimeMs > old.getTime() + 1000, 'used is touched');
  assert.equal(fs.statSync(at(keeper, 'memo/idle')).mtimeMs, old.getTime(), 'unused ages');
  fs.rmSync(root, { recursive: true, force: true });
});
