// GitHub's post-job cache policy cannot be exercised by a local shell test.
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const YAML = require('yaml');
const { read } = require('./helpers/source');

const job = YAML.parse(read('.github/workflows/build-and-test.yml')).jobs.validate;
const verify = job.steps.find((s) => s.id === 'formal-verify');

test('formal verification leaves time for cache saving before the job deadline', () => {
  assert.ok(verify, 'the verification step must have an outcome the save steps can read');
  assert.ok(verify['timeout-minutes'] > 0);
  assert.ok(verify['timeout-minutes'] < (job['timeout-minutes'] ?? 360));
  assert.equal(verify['continue-on-error'] ?? false, false, 'timeouts must still fail CI');
});

for (const id of ['formal-cache', 'tlapm-cache']) {
  test(`${id} saves completed work after a failed or cancelled verification`, () => {
    const restore = job.steps.find((s) => s.id === id);
    assert.equal(restore?.uses, 'actions/cache/restore@v4');
    const save = job.steps.find((s) => s.uses === 'actions/cache/save@v4'
      && s.with.key === '${{ steps.' + id + '.outputs.cache-primary-key }}');
    assert.ok(save, `${id} has no separate save step`);
    assert.ok(job.steps.indexOf(restore) < job.steps.indexOf(verify));
    assert.ok(job.steps.indexOf(save) > job.steps.indexOf(verify));
    assert.equal(save.with.path, restore.with.path);
    assert.match(restore.with.key, /github\.run_id/);
    assert.match(restore.with.key, /github\.run_attempt/);
    const guard = save.if.trim().slice(3, -2)
      .replaceAll('steps.formal-verify.outcome', 'outcome');
    for (const outcome of ['success', 'failure', 'cancelled', 'skipped', '']) {
      const shouldSave = vm.runInNewContext(guard, { outcome, always: () => true });
      assert.equal(shouldSave, ['success', 'failure', 'cancelled'].includes(outcome), outcome);
    }
  });
}
