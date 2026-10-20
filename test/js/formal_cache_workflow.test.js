// GitHub's post-job cache policy and workflow dependencies cannot run in a local shell test.
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const YAML = require('yaml');
const { read } = require('./helpers/source');

const jobs = YAML.parse(read('.github/workflows/formal.yml')).jobs;
const main = YAML.parse(read('.github/workflows/build-and-test.yml'));

for (const [name, id] of [['models', 'formal-cache'], ['proofs', 'tlapm-cache']]) {
  const job = jobs[name];
  const verify = job.steps.find((s) => s.id === 'formal-verify');
  test(`${name} leaves time to save completed work after a timeout`, () => {
    assert.ok(verify['timeout-minutes'] > 0);
    assert.ok(verify['timeout-minutes'] < (job['timeout-minutes'] ?? 360));
    assert.equal(verify['continue-on-error'] ?? false, false);
  });
  test(`${id} saves completed work after failure and skips restoration in cold mode`, () => {
    const restore = job.steps.find((s) => s.id === id);
    const save = job.steps.find((s) => s.uses === 'actions/cache/save@v4');
    assert.equal(restore.uses, 'actions/cache/restore@v4');
    assert.equal(restore.if, '${{ !inputs.cold }}');
    assert.equal(save.with.path, restore.with.path);
    assert.equal(save.with.key, restore.with.key);
    assert.match(save.with.key, /github\.run_id/);
    assert.match(save.with.key, /github\.run_attempt/);
    assert.ok(job.steps.indexOf(restore) < job.steps.indexOf(verify));
    assert.ok(job.steps.indexOf(save) > job.steps.indexOf(verify));
    const guard = save.if.trim().slice(3, -2).replaceAll('steps.formal-verify.outcome', 'outcome');
    for (const outcome of ['success', 'failure', 'cancelled', 'skipped', '']) {
      assert.equal(vm.runInNewContext(guard, { outcome, always: () => true }),
        ['success', 'failure', 'cancelled'].includes(outcome), outcome);
    }
  });
  test(`${id} falls back to master's newest artifact, which only master's pushes upload`, () => {
    const restore = job.steps.find((s) => s.id === id);
    const fallback = job.steps.find((s) => (s.run ?? '').includes('restore_formal_artifact.sh'));
    const upload = job.steps.find((s) => s.uses === 'actions/upload-artifact@v4' &&
      s.with.path === restore.with.path);
    assert.equal(fallback.if, `\${{ !inputs.cold && steps.${id}.outputs.cache-matched-key == '' }}`);
    assert.equal(fallback.env.GH_TOKEN, '${{ github.token }}');
    assert.ok(job.steps.indexOf(restore) < job.steps.indexOf(fallback));
    assert.ok(job.steps.indexOf(fallback) < job.steps.indexOf(verify));
    assert.ok(job.steps.indexOf(upload) > job.steps.indexOf(verify));
    const dest = restore.with.path.replace(/^~/, '$HOME');
    assert.ok(fallback.run.endsWith(` "${upload.with.name}" "${dest}"`), fallback.run);
    assert.equal(upload.with['include-hidden-files'], true);
    assert.equal(upload.with.overwrite, true);
    const guard = upload.if.trim().slice(3, -2)
      .replaceAll('steps.formal-verify.outcome', 'outcome')
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

test('cold model checks cannot use a valid memo or timing history', () => {
  const verify = jobs.models.steps.find((s) => s.id === 'formal-verify');
  assert.equal(verify.env.FORMAL_RERUN, "${{ inputs.cold && '1' || '' }}");
  assert.match(verify.run, /rm -rf "\$HOME\/\.cache\/webspace-formal"/);
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
  assert.ok(jobs.models.strategy.matrix.shard.length > 1);
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
