const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scriptOf } = require('./helpers/script_of');

const formalDir = path.resolve(__dirname, '../../formal');

/** A repository whose verify.sh runs the real PRINT and SCHEDULES stages over
 * stub tools, stopping at LEAN, and reports which of them did work. */
function repository(t, { plant = null } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'formal-resume-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const root = path.join(dir, 'repo');
  const formal = path.join(root, 'formal');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(path.join(formal, 'lean'), { recursive: true });
  fs.mkdirSync(path.join(root, 'lib'));
  fs.mkdirSync(bin);
  fs.copyFileSync(path.join(formalDir, 'verify.sh'), path.join(formal, 'verify.sh'));
  const key = fs.readFileSync(path.join(formalDir, 'input_key.py'), 'utf8');
  fs.writeFileSync(path.join(formal, 'input_key.py'), plant === null ? key
    : `import sys\nsys.argv += ['--plant', ${JSON.stringify(plant)}]\n` + key);
  fs.writeFileSync(path.join(root, '.gitignore'), '/build/\n');
  fs.writeFileSync(path.join(root, 'lib/site.dart'), 'void main() {}\n');
  const node = `#!${process.execPath}\n`;
  fs.writeFileSync(path.join(formal, 'check.sh'), node + scriptOf(() => {
    if (process.argv[2] === '--jar') {
      require('node:fs').writeFileSync(process.env.TLA2TOOLS_JAR, 'stub');
    }
  }), { mode: 0o755 });
  fs.writeFileSync(path.join(formal, 'lean/check.sh'), node + scriptOf(() => {
    process.exitCode = 77;
  }), { mode: 0o755 });
  for (const name of ['java', 'tlapm', 'lake']) {
    fs.writeFileSync(path.join(bin, name), node, { mode: 0o755 });
  }
  const events = path.join(dir, 'events');
  fs.writeFileSync(path.join(bin, 'flutter'), node + scriptOf((log) => {
    const fs = require('node:fs');
    const path = require('node:path');
    if (process.argv.includes('--version')) {
      console.log(process.env.STUB_FLUTTER_VERSION ?? 'Flutter 0.0.0');
      return;
    }
    if (process.env.FORMAL_OUT) {
      fs.mkdirSync(process.env.FORMAL_OUT, { recursive: true });
      fs.writeFileSync(path.join(process.env.FORMAL_OUT, 'models.json'), '{}');
      fs.appendFileSync(log, 'print\n');
      process.exitCode = 79;
      return;
    }
    fs.mkdirSync(process.env.MODEL_STEPS_DIR, { recursive: true });
    fs.writeFileSync(path.join(process.env.MODEL_STEPS_DIR, 'trace.json'), '[]');
    fs.appendFileSync(log, `shard ${process.env.SCHEDULE_SHARD}\n`);
    console.log('00:00 +0: loading schedules');
    if (process.env.SCHEDULE_SHARD === process.env.STUB_FAIL_SHARD) process.exitCode = 1;
  }, events), { mode: 0o755 });
  const git = (...args) => spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  git('init', '-q');

  return {
    root,
    /** Runs verify.sh with [env] added and returns the stages that did work. */
    verify(args, env = {}) {
      fs.rmSync(events, { force: true });
      const result = spawnSync('bash', [path.join(formal, 'verify.sh'), ...args], {
        cwd: root,
        env: {
          ...process.env,
          PATH: `${bin}${path.delimiter}${process.env.PATH}`,
          FLUTTER: 'flutter',
          FORMAL_SLOTS: '2',
          TLA2TOOLS_JAR: path.join(dir, 'tla2tools.jar'),
          ...env,
        },
        encoding: 'utf8',
        timeout: 20000,
      });
      assert.ifError(result.error);
      assert.equal(result.status, env.STUB_FAIL_SHARD ? 1 : 77, result.stdout + result.stderr);
      return fs.existsSync(events)
        ? fs.readFileSync(events, 'utf8').trim().split('\n').sort() : [];
    },
  };
}

const everything = ['print', 'shard 0/2', 'shard 1/2'];

test('--resume keeps the printed model and every schedule shard made under the same key', (t) => {
  const repo = repository(t);
  assert.deepEqual(repo.verify(['--resume']), everything);
  assert.deepEqual(repo.verify(['--resume']), []);
});

test('--resume redoes the stages once any input changes', (t) => {
  const repo = repository(t);
  assert.deepEqual(repo.verify(['--resume']), everything);
  fs.writeFileSync(path.join(repo.root, 'lib/site.dart'), 'void main() { print(1); }\n');
  assert.deepEqual(repo.verify(['--resume']), everything);
  fs.writeFileSync(path.join(repo.root, 'lib/new.dart'), '\n');
  assert.deepEqual(repo.verify(['--resume']), everything);
});

test('--resume redoes the stages under other schedule bounds or another toolchain', (t) => {
  const repo = repository(t);
  assert.deepEqual(repo.verify(['--resume']), everything);
  assert.deepEqual(repo.verify(['--resume'], { SCHEDULE_LENGTH: '4' }), everything);
  assert.deepEqual(repo.verify(['--resume'], { SCHEDULE_LENGTH: '4' }), []);
  assert.deepEqual(repo.verify(['--resume'], { WALK_SEEDS: '2' }), everything);
  assert.deepEqual(repo.verify(['--resume'], { STUB_FLUTTER_VERSION: 'Flutter 9.9.9' }), everything);
});

test('a shard that failed, or one of a run split another way, is not kept', (t) => {
  const repo = repository(t);
  assert.deepEqual(repo.verify(['--resume']), everything);
  const steps = path.join(repo.root, 'build/formal/steps');
  fs.rmSync(path.join(steps, '1/.key'));
  fs.mkdirSync(path.join(steps, '5'));
  assert.deepEqual(repo.verify(['--resume']), ['shard 1/2']);
  assert.ok(!fs.existsSync(path.join(steps, '5')), 'a shard of another split joins the replay');
});

test('shards run a few at a time are each kept as they end, so a stop loses only the ones under way', (t) => {
  const repo = repository(t);
  const oneAtATime = { FORMAL_PARALLEL: '1', FORMAL_SLOTS: '3' };
  assert.deepEqual(repo.verify(['--resume'], { ...oneAtATime, STUB_FAIL_SHARD: '2/3' }),
    ['print', 'shard 0/3', 'shard 1/3', 'shard 2/3']);
  assert.deepEqual(repo.verify(['--resume'], oneAtATime), ['shard 2/3']);
  assert.deepEqual(repo.verify(['--resume'], oneAtATime), []);
});

test('a run without --resume keeps nothing', (t) => {
  const repo = repository(t);
  assert.deepEqual(repo.verify(['--resume']), everything);
  assert.deepEqual(repo.verify([]), everything);
});

test('planted: a key that leaves out lib/ keeps a stale model and is caught', (t) => {
  const repo = repository(t, { plant: 'lib/' });
  assert.deepEqual(repo.verify(['--resume']), everything);
  fs.writeFileSync(path.join(repo.root, 'lib/site.dart'), 'void main() { print(1); }\n');
  assert.notDeepEqual(repo.verify(['--resume']), everything,
    'the gate above would pass a key that does not read lib/');
});

test('planted: a key that leaves out the schedule bounds keeps a stale shard and is caught', (t) => {
  const repo = repository(t, { plant: 'SCHEDULE_' });
  assert.deepEqual(repo.verify(['--resume']), everything);
  assert.notDeepEqual(repo.verify(['--resume'], { SCHEDULE_LENGTH: '4' }), everything,
    'the gate above would pass a key that does not read SCHEDULE_LENGTH');
});

// No type says which variables a Dart test reads, so the walk's reads are
// held to the prefixes input_key.py keys on, from the source.
test('every variable the schedules and walks read is one the key reads', () => {
  const root = path.resolve(__dirname, '../..');
  const prefixes = [...fs.readFileSync(path.join(formalDir, 'input_key.py'), 'utf8')
    .match(/^ENV_PREFIXES = \((.*)\)$/m)[1].matchAll(/"([A-Z_]+)"/g)].map((m) => m[1]);
  // Set by verify.sh for each shard, naming where it writes; not a bound.
  const perShard = new Set(['MODEL_STEPS_DIR']);
  const files = ['test/activation_schedules_test.dart', 'test/formal_model/main.dart',
    ...fs.readdirSync(path.join(root, 'test/helpers/walk'))
      .filter((f) => f.endsWith('.dart')).map((f) => `test/helpers/walk/${f}`)];
  const read = new Set();
  for (const file of files) {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    for (const m of text.matchAll(/(?:environment|env)\[\s*'([A-Z_]+)'\s*\]/g)) read.add(m[1]);
    for (const m of text.matchAll(/_env\(\s*'([A-Z_]+)'/g)) read.add(m[1]);
  }
  assert.ok(read.has('SCHEDULE_LENGTH') && read.has('WALK_SEED'), 'the scan finds the reads');
  const missedBy = (keyed) =>
    [...read].filter((v) => !perShard.has(v) && !keyed.some((p) => v.startsWith(p)));
  assert.deepEqual(missedBy(prefixes), [], 'a variable the walk reads that the resume key does not');
  assert.deepEqual(missedBy(prefixes.filter((p) => p !== 'WALK_')).sort(), ['WALK_SEED', 'WALK_SEEDS'],
    'planted: a key without WALK_ is caught');
});
