const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function checkProofs(t, { outcome, shortModule = '' }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-exit-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin');
  const model = path.join(dir, 'model');
  const tmp = path.join(dir, 'tmp');
  for (const folder of [bin, model, tmp]) fs.mkdirSync(folder);
  for (const name of [
    'activation_tables', 'activation_tables_proof', 'activation_invariants_proof',
    'activation_tables_3_proof', 'activation_tables_4_proof',
  ]) {
    fs.writeFileSync(path.join(model, `${name}.tla`), '');
  }
  // Stub only the prover: exercise the real orchestration, gate and EXIT trap.
  fs.writeFileSync(path.join(bin, 'tlapm'), [
    '#!/usr/bin/env bash',
    'if [[ -n "$PROOF_SHORT_MODULE" && "${@: -1}" == *"/$PROOF_SHORT_MODULE" ]]; then',
    '  echo "All 1 obligations proved."',
    'else',
    '  echo "All $PROOF_OBLIGATIONS obligations proved."',
    'fi',
  ].join('\n'), { mode: 0o755 });
  const result = spawnSync('bash', ['formal/proofs/check_proofs.sh'], {
    cwd: path.resolve(__dirname, '../..'),
    env: {
      ...process.env,
      PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      FORMAL_MODEL: model,
      TLAPM_JOBS: '32',
      TMPDIR: tmp,
      PROOF_OBLIGATIONS: outcome === 'failure' ? '0' : '1000',
      PROOF_SHORT_MODULE: shortModule,
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

for (const part of [3, 4]) {
  test(`a truncated table proof in part ${part} cannot pass with an all-proved summary`, (t) => {
    const { result, tmp } = checkProofs(t, {
      outcome: 'partial', shortModule: `activation_tables_${part}_proof.tla`,
    });
    assert.match(result.stdout, /FAIL: the tables' step modules proved only 1001 obligations/);
    assert.doesNotMatch(result.stdout, /All TLAPS proofs checked\./);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.deepEqual(fs.readdirSync(tmp), []);
  });
}
