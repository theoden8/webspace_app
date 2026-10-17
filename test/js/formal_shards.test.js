const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scriptOf } = require('./helpers/script_of');

function schedules(t, { failure = false } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'formal-shards-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const formal = path.join(dir, 'formal');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(path.join(formal, 'lean'), { recursive: true });
  fs.mkdirSync(bin);
  fs.copyFileSync(path.resolve(__dirname, '../../formal/verify.sh'), path.join(formal, 'verify.sh'));
  const node = `#!${process.execPath}\n`;
  for (const name of ['java', 'python3', 'tlapm', 'lake']) {
    fs.writeFileSync(path.join(bin, name), node, { mode: 0o755 });
  }
  // Stop at the next phase: only the real printer/shard orchestration runs.
  const reached = path.join(dir, 'lean-reached');
  fs.writeFileSync(path.join(formal, 'lean/check.sh'), node + scriptOf((file) => {
    require('node:fs').writeFileSync(file, 'reached');
    process.exitCode = 77;
  }, reached), { mode: 0o755 });
  const events = path.join(dir, 'events.jsonl');
  fs.writeFileSync(path.join(bin, 'flutter'), node + scriptOf(() => {
    const fs = require('node:fs');
    const path = require('node:path');
    if (process.env.FORMAL_OUT) {
      fs.mkdirSync(process.env.FORMAL_OUT, { recursive: true });
      fs.writeFileSync(path.join(process.env.FORMAL_OUT, 'models.json'), '{}');
      process.exitCode = 79;
      return;
    }
    const shard = Number(process.env.SCHEDULE_SHARD.split('/')[0]);
    const args = process.argv.slice(2);
    const index = args.indexOf('--reporter');
    const reporter = index >= 0 ? args[index + 1] : 'github';
    const record = (event) => fs.appendFileSync(process.env.SHARD_TEST_EVENTS,
      JSON.stringify({ shard, event, reporter }) + '\n');
    record('copy');
    setTimeout(() => {
      record('loading');
      console.log(reporter === 'expanded' ? '00:00 +0: loading schedules' : '::group::schedules');
      setTimeout(() => {
        record('end');
        if (process.env.SHARD_TEST_FAIL === 'true' && shard === 1) {
          console.log('Some tests failed.');
          process.exitCode = 1;
        } else console.log('All tests passed!');
      }, 2100);
    }, 50);
  }), { mode: 0o755 });
  const result = spawnSync('bash', [path.join(formal, 'verify.sh')], {
    env: {
      ...process.env,
      PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      FLUTTER: 'flutter',
      FORMAL_SLOTS: '2',
      GITHUB_ACTIONS: 'true',
      SHARD_TEST_EVENTS: events,
      SHARD_TEST_FAIL: String(failure),
    },
    encoding: 'utf8',
    timeout: 20000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return {
    result,
    reached: fs.existsSync(reached),
    events: fs.readFileSync(events, 'utf8').trim().split('\n').map((s) => JSON.parse(s)),
  };
}

test('CI schedule shards overlap after their asset copies finish', (t) => {
  const run = schedules(t);
  assert.equal(run.result.status, 77, run.result.stdout + run.result.stderr);
  assert.ok(run.reached);
  let copying = 0;
  let running = 0;
  let peak = 0;
  for (const event of run.events) {
    if (event.event === 'copy') { copying++; running++; }
    if (event.event === 'loading') copying--;
    if (event.event === 'end') running--;
    assert.ok(copying <= 1, 'asset copying must remain serialized');
    peak = Math.max(peak, running);
  }
  assert.equal(peak, 2, 'one shard must start while the other is still running');
  assert.equal(running, 0);
  assert.ok(run.events.every((e) => e.reporter === 'expanded'));
});

test('a failed schedule shard still fails verification before Lean', (t) => {
  const run = schedules(t, { failure: true });
  assert.equal(run.result.status, 1, run.result.stdout + run.result.stderr);
  assert.equal(run.reached, false);
  assert.equal(run.events.filter((e) => e.event === 'end').length, 2);
  assert.match(run.result.stdout, /Some tests failed\./);
});
