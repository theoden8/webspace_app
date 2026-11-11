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
// whose outcome says there is something to keep). The proof shards each keep
// a slice of their own, below.
const stages = [
  { name: 'models', id: 'formal-cache', keeper: 'memo', work: 'formal-merge' },
  { name: 'steps', id: 'replay-cache', keeper: 'steps', work: 'formal-verify' },
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

// The proof shards: each restores every shard's slice into one directory,
// so a module the split moves stays warm, and saves its own.
const proofs = jobs.proofs;
const slices = proofs.strategy.matrix.shard;
const proofVerify = proofs.steps.find((s) => s.id === 'formal-verify');
test('each proof shard restores every slice before it proves, and saves its own after', () => {
  assert.ok(slices.length > 1);
  assert.equal(proofs.strategy['fail-fast'], false);
  assert.equal(proofVerify.env.FORMAL_PROOF_SHARD, '${{ strategy.job-index }}/${{ strategy.job-total }}');
  assert.ok(proofVerify['timeout-minutes'] > 0, 'a shard leaves time to save what it proved');
  assert.ok(proofVerify['timeout-minutes'] < (proofs['timeout-minutes'] ?? 360));
  const prefix = '${{ steps.tools.outputs.tlapm-pin }}';
  const restores = proofs.steps.filter((s) => s.uses === 'actions/cache/restore@v4');
  assert.deepEqual(restores.map((s) => s.id), ['tlapm-cache', ...slices.map((k) => `tlapm-cache-${k}`)]);
  for (const restore of restores) {
    assert.equal(restore.if, '${{ !inputs.cold }}');
    assert.equal(restore.with.path, 'formal/proofs/.tlacache');
    assert.ok(proofs.steps.indexOf(restore) < proofs.steps.indexOf(proofVerify));
  }
  for (const k of slices) {
    const restore = restores.find((s) => s.id === `tlapm-cache-${k}`);
    assert.equal(restore.with['restore-keys'], `tlapm-\${{ runner.os }}-${prefix}-s${k}-`);
  }
  const save = proofs.steps.find((s) => s.uses === 'actions/cache/save@v4');
  assert.equal(save.with.path, 'formal/proofs/.tlacache');
  assert.equal(save.with.key,
    `tlapm-\${{ runner.os }}-${prefix}-s\${{ strategy.job-index }}-\${{ github.run_id }}-\${{ github.run_attempt }}`);
  assert.ok(proofs.steps.indexOf(save) > proofs.steps.indexOf(proofVerify));
  const guard = save.if.trim().slice(3, -2).replaceAll('steps.formal-verify.outcome', 'outcome');
  for (const outcome of ['success', 'failure', 'cancelled', 'skipped', '']) {
    assert.equal(vm.runInNewContext(guard, { outcome, always: () => true }),
      ['success', 'failure', 'cancelled'].includes(outcome), outcome);
  }
});

test("a proof shard with no cache at all takes master's newest artifact of every slice", () => {
  const fallback = proofs.steps.find((s) => (s.run ?? '').includes('restore_formal_artifact.sh'));
  for (const id of ['tlapm-cache', ...slices.map((k) => `tlapm-cache-${k}`)]) {
    assert.match(fallback.if, new RegExp(`steps\\.${id}\\.outputs\\.cache-matched-key == ''`), id);
  }
  assert.equal(fallback.env.GH_TOKEN, '${{ github.token }}');
  assert.ok(proofs.steps.indexOf(fallback) < proofs.steps.indexOf(proofVerify));
  const upload = proofs.steps.find((s) => s.uses === 'actions/upload-artifact@v4' &&
    s.with.path === 'formal/proofs/.tlacache');
  assert.equal(upload.with.name, 'formal-tlacache-${{ steps.tools.outputs.tlapm-pin }}-${{ strategy.job-index }}');
  assert.match(fallback.run, new RegExp(`-\\{${slices.join(',')}\\}`));
  assert.equal(upload.with['include-hidden-files'], true);
  const guard = upload.if.trim().slice(3, -2)
    .replaceAll('steps.formal-verify.outcome', 'outcome')
    .replaceAll('github.event_name', 'event').replaceAll('github.ref', 'ref');
  for (const [event, ref] of [['push', 'refs/heads/master'], ['pull_request', 'refs/heads/master']]) {
    for (const outcome of ['success', 'failure', 'skipped']) {
      assert.equal(vm.runInNewContext(guard, { event, ref, outcome, always: () => true }),
        event === 'push' && outcome !== 'skipped', `${event} ${outcome}`);
    }
  }
});

test('the finish merges every proof shard\'s report', () => {
  const download = jobs.finish.steps.find((s) => s.with?.pattern === 'formal-proofs-*');
  assert.equal(download.with.path, 'build/formal/proof-shards');
  const report = proofs.steps.find((s) => s.with?.name === 'formal-proofs-${{ strategy.job-index }}');
  assert.equal(report.with.path, 'build/formal/proofs.log');
  assert.match(read('formal/verify.sh'), /proof_shards\.py" merge/);
});

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
  assert.ok(Math.abs(fs.statSync(at(keeper, 'memo/idle')).mtimeMs - old.getTime()) < 1000, 'unused ages');
  fs.rmSync(root, { recursive: true, force: true });
});

// The TLAPS release asset is rebuilt in place upstream under the same version
// string, so a proof cache keyed on `tlapm --version` went cold without notice.
// A workflow's keys have no type, so the pin is held here.
const setup = YAML.parse(read('.github/actions/setup-formal/action.yml'));
const setupStep = (id) => setup.runs.steps.find((s) => s.id === id);

test('the proof cache is keyed on the pinned TLAPS build, never on its version string', () => {
  assert.match(setupStep('pin').run, /sha256=[0-9a-f]{64}"/, 'the pin names one SHA-256');
  const dist = setup.runs.steps.find((s) => s.with?.path === '~/tlapm-dist');
  assert.equal(dist.uses, './.github/actions/master-cache', 'only master saves the tarball');
  assert.match(dist.with.key, /\$\{\{ steps\.pin\.outputs\.sha256 \}\}$/);
  assert.equal(setupStep('tlapm').env.TLAPM_SHA256, '${{ steps.pin.outputs.sha256 }}');
  assert.equal(setup.outputs['tlapm-pin'].value, '${{ steps.tlapm.outputs.pin }}');
  const proofs = jobs.proofs.steps;
  assert.doesNotMatch(JSON.stringify(proofs), /tlapm-version|tlapm --version/);
  assert.match(proofs.find((s) => s.id === 'tlapm-cache').with.key,
    /^tlapm-\$\{\{ runner\.os \}\}-\$\{\{ steps\.tools\.outputs\.tlapm-pin \}\}-/);
});

test('a TLAPS tarball that is not the pinned build fails the install, and the pinned one installs', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'tlapm-pin-'));
  const build = path.join(home, 'build');
  fs.mkdirSync(path.join(build, 'tlapm', 'bin'), { recursive: true });
  fs.writeFileSync(path.join(build, 'tlapm', 'bin', 'tlapm'), '#!/bin/sh\necho "TLAPS fake"\n',
    { mode: 0o755 });
  fs.mkdirSync(path.join(home, 'tlapm-dist'));
  const tarball = path.join(home, 'tlapm-dist', 'tlapm.tar.gz');
  execFileSync('tar', ['-czf', tarball, '-C', build, 'tlapm']);
  const sha = execFileSync('sha256sum', [tarball], { encoding: 'utf8' }).split(' ')[0];
  const install = (pinned) => {
    const out = path.join(home, `out-${pinned.slice(0, 8)}`);
    fs.writeFileSync(out, '');
    try {
      execFileSync('bash', ['-eo', 'pipefail', '-c', setupStep('tlapm').run], {
        env: { ...process.env, HOME: home, GITHUB_OUTPUT: out,
          GITHUB_PATH: path.join(home, 'path'), TLAPM_URL: 'http://127.0.0.1:9/unreachable',
          TLAPM_SHA256: pinned },
        stdio: 'pipe',
      });
      return { ok: true, out: fs.readFileSync(out, 'utf8') };
    } catch (e) {
      return { ok: false, out: fs.readFileSync(out, 'utf8'), said: String(e.stdout) };
    }
  };
  const other = install('0'.repeat(64));
  assert.equal(other.ok, false, 'a rebuilt asset fails the install');
  assert.match(other.said, /upstream rebuilt it/);
  assert.equal(other.out, '', 'and names no pin');
  const pinned = install(sha);
  assert.equal(pinned.ok, true);
  assert.equal(pinned.out.trim(), `pin=${sha}`);
  fs.rmSync(home, { recursive: true, force: true });
});
