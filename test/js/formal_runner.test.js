const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scriptOf } = require('./helpers/script_of');

function runner(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'formal-runner-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const root = path.resolve(__dirname, '../..');
  const formal = path.join(dir, 'formal');
  const bin = path.join(dir, 'bin');
  const model = path.join(dir, 'model');
  for (const folder of [formal, bin, model]) fs.mkdirSync(folder);
  for (const name of fs.readdirSync(path.join(root, 'formal'))) {
    if (/\.(tla|cfg)$/.test(name) || name === 'check.sh') {
      fs.copyFileSync(path.join(root, 'formal', name), path.join(formal, name));
    }
  }
  fs.writeFileSync(path.join(model, 'activation_tables.tla'), '');
  fs.writeFileSync(path.join(model, 'checks.tsv'), '');
  fs.writeFileSync(path.join(dir, 'tla2tools.jar'), 'stub');
  fs.writeFileSync(path.join(bin, 'java'), `#!${process.execPath}\n` + scriptOf(() => {
    const fs = require('node:fs');
    const path = require('node:path');
    const args = process.argv.slice(2);
    const config = path.basename(args[args.indexOf('-config') + 1]);
    const workers = Number(args[args.indexOf('-workers') + 1]);
    const record = (event) => fs.appendFileSync(process.env.TLC_TEST_CALLS,
      JSON.stringify({ event, config, workers, pid: process.pid }) + '\n');
    record('start');
    console.log('Progress(1): 100 states generated, 50 distinct states found');
    setTimeout(() => {
      record('end');
      if (process.env.TLC_TEST_FAIL === 'true') {
        console.log('Error: planted backend failure');
        process.exitCode = 1;
        return;
      }
      const verdicts = {
        'kernel.cfg': 'No error has been found',
        'kernel_conflict_repaint.cfg': 'Temporal properties were violated',
        'kernel_conflict_evict.cfg': 'Inv_CurrentLoaded is violated',
        'kernel_conflict_contaminate.cfg': 'Inv_JarMatchesVisible is violated',
      };
      console.log(verdicts[config]);
    }, Number(process.env.TLC_TEST_DELAY));
  }), { mode: 0o755 });
  const calls = path.join(dir, 'calls.jsonl');
  return {
    events: () => fs.existsSync(calls)
      ? fs.readFileSync(calls, 'utf8').trim().split('\n').map((s) => JSON.parse(s)) : [],
    memo: path.join(dir, 'cache', 'memo'),
    times: path.join(dir, 'cache', 'times'),
    run({ section = 'GOOD', delay = 0, failure = false } = {}) {
      const result = spawnSync('bash', [path.join(formal, 'check.sh')], {
        env: {
          ...process.env,
          PATH: `${bin}${path.delimiter}${process.env.PATH}`,
          FORMAL_MODEL: model,
          FORMAL_CACHE: path.join(dir, 'cache'),
          TLA2TOOLS_JAR: path.join(dir, 'tla2tools.jar'),
          FORMAL_ONLY: section,
          FORMAL_SLOTS: '4',
          FORMAL_PROGRESS_SECONDS: '1',
          FORMAL_RERUN: '',
          TLC_TEST_CALLS: calls,
          TLC_TEST_DELAY: String(delay),
          TLC_TEST_FAIL: String(failure),
        },
        encoding: 'utf8',
        timeout: 15000,
      });
      assert.ifError(result.error);
      assert.equal(result.signal, null);
      return result;
    },
  };
}

test('a sole cold TLC check uses every core and its result is reused', (t) => {
  const check = runner(t);
  const first = check.run();
  assert.equal(first.status, 0, first.stdout + first.stderr);
  assert.match(first.stdout, /TALLY holds=1 caught=0 reached=0/);
  assert.equal(check.events()[0].workers, 4);
  const second = check.run();
  assert.equal(second.status, 0, second.stdout + second.stderr);
  assert.match(second.stdout, /\(remembered\)/);
  assert.match(second.stdout, /TALLY holds=1 caught=0 reached=0/);
  assert.equal(check.events().length, 2, 'a cache hit must not launch Java');
});

test('cold checks share the cores and print progress before completing', (t) => {
  const check = runner(t);
  const result = check.run({ section: 'NEGATIVE', delay: 1800 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /TALLY holds=0 caught=3 reached=0/);
  assert.match(result.stdout, /RUN +kernel_conflict_repaint.cfg: 2 workers/);
  assert.match(result.stdout, /Progress\(1\): 100 states generated/);
  let active = 0;
  let peak = 0;
  for (const event of check.events()) {
    assert.equal(event.workers, 2);
    active += event.event === 'start' ? event.workers : -event.workers;
    peak = Math.max(peak, active);
    assert.ok(active <= 4, 'the pool exceeded its core budget');
  }
  assert.equal(peak, 4, 'independent checks should run concurrently');
  assert.equal(active, 0);
});

test('failed TLC checks remain failures and are not remembered', (t) => {
  const check = runner(t);
  const failed = check.run({ failure: true });
  assert.equal(failed.status, 1, failed.stdout + failed.stderr);
  assert.match(failed.stdout + failed.stderr, /FAIL: kernel.cfg/);
  assert.deepEqual(fs.readdirSync(check.memo), []);
  const retry = check.run();
  assert.equal(retry.status, 0, retry.stdout + retry.stderr);
  assert.equal(check.events().length, 4, 'the failed check must run again');
});

test('recorded timings still prioritize the expensive check within the core budget', (t) => {
  const check = runner(t);
  fs.mkdirSync(check.times, { recursive: true });
  for (const [name, seconds] of [
    ['kernel_conflict_repaint', 90],
    ['kernel_conflict_evict', 5],
    ['kernel_conflict_contaminate', 5],
  ]) fs.writeFileSync(path.join(check.times, name), `${seconds} 1\n`);
  const result = check.run({ section: 'NEGATIVE', delay: 200 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const starts = check.events().filter((e) => e.event === 'start');
  const workers = Object.fromEntries(starts.map((e) => [e.config, e.workers]));
  assert.deepEqual(workers, {
    'kernel_conflict_repaint.cfg': 3,
    'kernel_conflict_evict.cfg': 1,
    'kernel_conflict_contaminate.cfg': 1,
  });
});
