const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scriptOf } = require('./helpers/script_of');

function verify(t, floor) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'formal-levels-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const formal = path.join(dir, 'formal');
  const bin = path.join(dir, 'bin');
  for (const folder of [formal, bin, ...['lean', 'trace', 'proofs'].map((s) => path.join(formal, s))]) {
    fs.mkdirSync(folder);
  }
  for (const name of ['verify.sh', 'levels.py', 'model_shards.py']) {
    fs.copyFileSync(path.resolve(__dirname, '../../formal', name), path.join(formal, name));
  }
  fs.writeFileSync(path.join(formal, 'levels.tsv'), Object.entries(floor)
    .map(([key, value]) => `${key}\t${value}\n`).join(''));
  for (const name of ['java', 'tlapm', 'lake']) {
    fs.writeFileSync(path.join(bin, name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  }
  fs.writeFileSync(path.join(bin, 'flutter'), `#!${process.execPath}\n` + scriptOf(() => {
    const fs = require('node:fs');
    const path = require('node:path');
    if (process.env.FORMAL_OUT) {
      fs.mkdirSync(process.env.FORMAL_OUT, { recursive: true });
      fs.writeFileSync(path.join(process.env.FORMAL_OUT, 'models.json'), '{}');
    } else console.log('00:00 +0: loading schedules');
  }), { mode: 0o755 });
  // Stub the expensive stages, keeping the real verification and levels gate.
  const stages = {
    'lean/check.sh': '',
    'trace/check_steps.sh': '  OK   first 2 steps, 3 states replayed\n  OK   second 2 steps, 3 states replayed (remembered)',
    'proofs/check_proofs.sh': '  OK: 2 obligations proved\n  OK: 2 obligations proved',
  };
  for (const [name, output] of Object.entries(stages)) {
    fs.writeFileSync(path.join(formal, name), `#!${process.execPath}\n` + scriptOf((text) => {
      console.log(text);
    }, output), { mode: 0o755 });
  }
  fs.writeFileSync(path.join(formal, 'check.sh'), `#!${process.execPath}\n` + scriptOf(() => {
    const fs = require('node:fs');
    const records = ['holds', 'caught', 'reached', 'holds', 'caught', 'reached']
      .map((kind, i) => `${i}\tcheck_${i}\t${kind}`);
    switch (process.argv[2]) {
      case '--jar':
        fs.writeFileSync(process.env.TLA2TOOLS_JAR ?? 'formal/tla2tools.jar', 'stub');
        return;
      case '--gates':
        return;
    }
    fs.writeFileSync(process.env.FORMAL_MANIFEST, ['SHARD\t0\t1',
      ...records.map((r) => `CHECK\t${r}`), 'PLANNED\t6', ''].join('\n'));
    if (process.argv[2] !== '--plan') {
      for (const row of records) console.log(`RESULT\t${row}`);
      console.log('TALLY holds=2 caught=2 reached=2');
    }
  }), { mode: 0o755 });
  const result = spawnSync('bash', [path.join(formal, 'verify.sh')], {
    env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, FLUTTER: 'flutter', FORMAL_SLOTS: '1' },
    encoding: 'utf8',
    timeout: 10000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return { result, out: path.join(dir, 'build/formal') };
}

const measured = { holds: 2, caught: 2, reached: 2, traces: 2, steps: 4, modules: 2, obligations: 4 };

test('verification accepts growth in every count while catching a floor above the measured run', (t) => {
  const { result, out } = verify(t, Object.fromEntries(Object.keys(measured).map((k) => [k, 1])));
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /OK {3}planted: a floor above the run is caught/);
  assert.match(result.stdout, /Every formal check passed\./);
  const levels = fs.readFileSync(path.join(out, 'levels.tsv'), 'utf8');
  assert.equal(levels, Object.entries(measured).map(([k, v]) => `${k}\t${v}\n`).join(''));
});

test('verification still rejects a measured count below the committed floor', (t) => {
  const { result } = verify(t, { ...measured, holds: 3 });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stderr, /levels: holds fell below formal\/levels.tsv/);
  assert.doesNotMatch(result.stdout, /Every formal check passed\./);
});
