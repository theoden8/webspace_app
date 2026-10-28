const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');

function proofRun(t, { outcome, shortModule = '', solvers = '', hang = false }) {
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
    // A backend's shell and the solver it starts, as tlapm runs one, the
    // solver's pid in a file named for the stub's once it runs; then the
    // shell goes and the solver does not, as on a backend timeout.
    'if [[ -n "$PROOF_SOLVERS" ]]; then',
    '  sh -c \'sleep 30 </dev/null >/dev/null 2>&1 & echo $! >"$0.tmp"; mv "$0.tmp" "$0"; wait\' "$PROOF_SOLVERS/$$" &',
    '  shell=$!',
    '  until [[ -e "$PROOF_SOLVERS/$$" ]]; do sleep 0.05; done',
    '  [[ -z "$PROOF_HANG" ]] || wait',
    '  kill "$shell"',
    'fi',
    'if [[ -n "$PROOF_SHORT_MODULE" && "${@: -1}" == *"/$PROOF_SHORT_MODULE" ]]; then',
    '  echo "All 1 obligations proved."',
    'else',
    '  echo "All $PROOF_OBLIGATIONS obligations proved."',
    'fi',
  ].join('\n'), { mode: 0o755 });
  return {
    tmp,
    modules: fs.readdirSync(model).filter((name) => name.endsWith('_proof.tla')).length +
      fs.readdirSync(path.join(root, 'formal/proofs')).filter((name) => name.endsWith('.tla')).length,
    options: {
      cwd: root,
      env: {
        ...process.env,
        PATH: `${bin}${path.delimiter}${process.env.PATH}`,
        FORMAL_MODEL: model,
        TLAPM_JOBS: '32',
        TMPDIR: tmp,
        PROOF_OBLIGATIONS: outcome === 'failure' ? '0' : '1000',
        PROOF_SHORT_MODULE: shortModule,
        PROOF_SOLVERS: solvers,
        PROOF_HANG: hang ? '1' : '',
      },
      encoding: 'utf8',
    },
  };
}

function checkProofs(t, run) {
  const { tmp, options } = proofRun(t, run);
  const result = spawnSync('bash', ['formal/proofs/check_proofs.sh'], { ...options, timeout: 30000 });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return { result, tmp };
}

function alive(pid) {
  const state = spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' }).stdout.trim();
  return state !== '' && !state.startsWith('Z');
}

// The stubs and the solvers they started, each the pid of one; one left
// running is stopped here, after the assertion that names it.
function solversOf(t) {
  const solvers = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-solvers-'));
  const pids = () => fs.readdirSync(solvers).filter((name) => /^\d+$/.test(name)).flatMap((stub) =>
    [Number(stub), Number(fs.readFileSync(path.join(solvers, stub), 'utf8'))]);
  t.after(() => {
    for (const pid of pids()) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
    }
    fs.rmSync(solvers, { recursive: true, force: true });
  });
  return { solvers, pids };
}

async function assertAllEnd(pids) {
  for (let tries = 0; tries < 40 && pids.some(alive); tries++) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.deepEqual(pids.filter(alive), []);
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

test('a solver whose shell timed out does not outlive its module', async (t) => {
  const { solvers, pids } = solversOf(t);
  const { result } = checkProofs(t, { outcome: 'success', solvers });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.notDeepEqual(pids(), []);
  await assertAllEnd(pids());
});

test('an interrupted proof run stops every prover it started', async (t) => {
  const { solvers, pids } = solversOf(t);
  const { options, modules } = proofRun(t, { outcome: 'success', solvers, hang: true });
  const run = spawn('bash', ['formal/proofs/check_proofs.sh'], { ...options, stdio: 'ignore' });
  const ended = new Promise((resolve) => run.on('exit', resolve));
  for (let tries = 0; tries < 200 && pids().length < 2 * modules; tries++) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(pids().length, 2 * modules);
  run.kill('SIGINT');
  await ended;
  await assertAllEnd(pids());
});
