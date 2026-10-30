const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');

function proofRun(t, {
  outcome, shortModule = '', solvers = '', hang = false, cache = null, rerun = false,
  script = 'formal/proofs/check_proofs.sh',
}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-exit-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin');
  const model = path.join(dir, 'model');
  const tmp = path.join(dir, 'tmp');
  for (const folder of [bin, model, tmp]) fs.mkdirSync(folder);
  for (const name of [
    'activation_tables', 'activation_tables_proof', 'activation_invariants_checksOffScreen_proof',
    'activation_tables_3_proof', 'activation_tables_4_proof',
  ]) {
    fs.writeFileSync(path.join(model, `${name}.tla`), '');
  }
  // Stub only the prover: exercise the real orchestration, gate and EXIT trap.
  fs.writeFileSync(path.join(bin, 'tlapm'), [
    '#!/usr/bin/env bash',
    'echo "${@: -1}" >>"$PROOF_CALLS"',
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
  const calls = path.join(dir, 'calls');
  fs.writeFileSync(calls, '');
  return {
    tmp,
    model,
    script,
    asked: () => fs.readFileSync(calls, 'utf8').split('\n').filter(Boolean),
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
        TLAPM_CACHE_DIR: cache ?? path.join(dir, 'cache'),
        FORMAL_RERUN: rerun ? '1' : '',
        PROOF_CALLS: calls,
        PROOF_OBLIGATIONS: outcome === 'failure' ? '0' : '1000',
        PROOF_SHORT_MODULE: shortModule,
        PROOF_SOLVERS: solvers,
        PROOF_HANG: hang ? '1' : '',
      },
      encoding: 'utf8',
    },
  };
}

function prove(run) {
  const result = spawnSync('bash', [run.script], { ...run.options, timeout: 30000 });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

function checkProofs(t, run) {
  const prepared = proofRun(t, run);
  return { result: prove(prepared), tmp: prepared.tmp };
}

// A cache two runs share, as CI and a local verify keep one.
function sharedCache(t) {
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-cache-'));
  t.after(() => fs.rmSync(cache, { recursive: true, force: true }));
  return cache;
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

// The memo's cases, each a function of the script it runs, so a planted
// copy of the script can be held to them (below).
const memoCases = [
  ['a module proved before under the same inputs is remembered, not proved again', (t, script) => {
    const cache = sharedCache(t);
    const first = proofRun(t, { outcome: 'success', cache, script });
    assert.equal(prove(first).status, 0);
    assert.equal(first.asked().length, first.modules);
    const again = proofRun(t, { outcome: 'success', cache, script });
    const result = prove(again);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /All TLAPS proofs checked\./);
    assert.deepEqual(again.asked(), []);
    assert.equal(result.stdout.match(/^ {2}OK: 1000 obligations proved \(>= \d+\) \(remembered\)$/gm)?.length, again.modules);
  }],
  ['a change to a module the proofs can read proves them again', (t, script) => {
    const cache = sharedCache(t);
    assert.equal(prove(proofRun(t, { outcome: 'success', cache, script })).status, 0);
    const changed = proofRun(t, { outcome: 'success', cache, script });
    fs.writeFileSync(path.join(changed.model, 'activation_tables.tla'), '\\* changed\n');
    assert.equal(prove(changed).status, 0);
    assert.equal(changed.asked().length, changed.modules);
  }],
  ['a module that falls short is not remembered', (t, script) => {
    const cache = sharedCache(t);
    assert.equal(prove(proofRun(t, { outcome: 'failure', cache, script })).status, 1);
    const next = proofRun(t, { outcome: 'success', cache, script });
    const result = prove(next);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.doesNotMatch(result.stdout, /again once the rest end/);
    assert.equal(next.asked().length, next.modules);
  }],
  // A pin raised after a module was kept: its kept output now falls short.
  ['a remembered module short of its pin is proved again', (t, script) => {
    const cache = sharedCache(t);
    assert.equal(prove(proofRun(t, { outcome: 'success', cache, script })).status, 0);
    const memo = path.join(cache, 'memo');
    for (const kept of fs.readdirSync(memo)) fs.writeFileSync(path.join(memo, kept), 'All 1 obligations proved.\n');
    const again = proofRun(t, { outcome: 'success', cache, script });
    prove(again);
    assert.ok(again.asked().includes('archive_identity.tla'), again.asked().join(' '));
  }],
  ['a remembered module is held to the tables\' sum', (t, script) => {
    const cache = sharedCache(t);
    const shortModule = 'activation_tables_3_proof.tla';
    assert.equal(prove(proofRun(t, { outcome: 'partial', shortModule, cache, script })).status, 1);
    const again = proofRun(t, { outcome: 'partial', shortModule, cache, script });
    const result = prove(again);
    assert.deepEqual(again.asked(), []);
    assert.match(result.stdout, /FAIL: the tables' step modules proved only 1001 obligations/);
    assert.equal(result.status, 1, result.stdout + result.stderr);
  }],
  ['FORMAL_RERUN proves every module again', (t, script) => {
    const cache = sharedCache(t);
    assert.equal(prove(proofRun(t, { outcome: 'success', cache, script })).status, 0);
    const rerun = proofRun(t, { outcome: 'success', cache, rerun: true, script });
    assert.equal(prove(rerun).status, 0);
    assert.equal(rerun.asked().length, rerun.modules);
  }],
];

for (const [name, run] of memoCases) test(name, (t) => run(t, undefined));

// check_proofs.sh with [from] replaced by [to], in a copy of the modules it
// reads from beside it, as it finds them in formal/.
function plantedScript(t, { from, to }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-planted-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const formal = path.join(dir, 'formal');
  fs.mkdirSync(path.join(formal, 'proofs'), { recursive: true });
  for (const [folder, kept] of [['formal', /\.tla$/], ['formal/proofs', /\.(tla|py)$/]]) {
    for (const name of fs.readdirSync(path.join(root, folder)).filter((n) => kept.test(n))) {
      fs.copyFileSync(path.join(root, folder, name), path.join(dir, folder, name));
    }
  }
  const source = fs.readFileSync(path.join(root, 'formal/proofs/check_proofs.sh'), 'utf8');
  assert.ok(source.includes(from), `not in check_proofs.sh: ${from}`);
  const script = path.join(formal, 'proofs/check_proofs.sh');
  fs.writeFileSync(script, source.replace(from, to), { mode: 0o755 });
  return script;
}

const planted = [
  ['a key that leaves out the inputs', 'a change to a module the proofs can read proves them again',
    'printf \'%s\\n\' "$INPUTS" "module $1 --safefp"', 'printf \'%s\\n\' "module $1 --safefp"'],
  ['a key that names the path', 'a module proved before under the same inputs is remembered, not proved again',
    'memo="$MEMO/$(key "model/$name")"', 'memo="$MEMO/$(key "$f")"'],
  ['a kept failure', 'a module that falls short is not remembered',
    '    echo "$f" >>"$work/again"', '    printf \'%s\\n\' "$out" >"$memo"; echo "$f" >>"$work/again"'],
  ['a remembered output let past its pin', 'a remembered module short of its pin is proved again',
    '  if [ -n "$proved" ] && [ "$proved" -ge "$want" ]; then',
    '  if [ -n "$kept" ] || { [ -n "$proved" ] && [ "$proved" -ge "$want" ]; }; then'],
  ['a rerun that remembers', 'FORMAL_RERUN proves every module again',
    '[ -z "${FORMAL_RERUN:-}" ] && ', ''],
];

test('a copy of the script with nothing planted passes every memo case', (t) => {
  for (const [, run] of memoCases) run(t, plantedScript(t, { from: '', to: '' }));
});

for (const [mistake, breaks, from, to] of planted) {
  test(`the memo's cases catch ${mistake}`, (t) => {
    const run = memoCases.find(([name]) => name === breaks)[1];
    assert.throws(() => run(t, plantedScript(t, { from, to })), assert.AssertionError);
  });
}
