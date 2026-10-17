const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function checkProofs(t, { outcome }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-exit-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin');
  const model = path.join(dir, 'model');
  const tmp = path.join(dir, 'tmp');
  for (const folder of [bin, model, tmp]) fs.mkdirSync(folder);
  for (const name of ['activation_tables', 'activation_tables_proof', 'activation_invariants_proof']) {
    fs.writeFileSync(path.join(model, `${name}.tla`), '');
  }
  // Stub only the prover: exercise the real orchestration, gate and EXIT trap.
  fs.writeFileSync(path.join(bin, 'tlapm'), [
    '#!/usr/bin/env bash',
    'echo "All $PROOF_OBLIGATIONS obligations proved."',
  ].join('\n'), { mode: 0o755 });
  const result = spawnSync('bash', ['formal/proofs/check_proofs.sh'], {
    cwd: path.resolve(__dirname, '../..'),
    env: {
      ...process.env,
      PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      FORMAL_MODEL: model,
      TLAPM_JOBS: '32',
      TMPDIR: tmp,
      PROOF_OBLIGATIONS: outcome === 'success' ? '1000' : '0',
    },
    encoding: 'utf8',
    timeout: 30000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return { result, tmp };
}

test('a successful proof run exits zero and removes its temporary directory', (t) => {
  const { result, tmp } = checkProofs(t, { outcome: 'success' });
  assert.match(result.stdout, /All TLAPS proofs checked\./);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.deepEqual(fs.readdirSync(tmp), []);
});

test('failed proof obligations still exit nonzero and remove their temporary directory', (t) => {
  const { result, tmp } = checkProofs(t, { outcome: 'failure' });
  assert.match(result.stdout, /FAIL: .* proved only 0 obligations/);
  assert.doesNotMatch(result.stdout, /All TLAPS proofs checked\./);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.deepEqual(fs.readdirSync(tmp), []);
});
