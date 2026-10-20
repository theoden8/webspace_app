const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'model-shards-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const records = ['holds', 'caught', 'reached', 'holds', 'caught', 'reached', 'holds']
    .map((kind, i) => `CHECK\t${i}\tcheck_${i}\t${kind}`);
  const manifest = (index, count) => [`SHARD\t${index}\t${count}`, ...records,
    `PLANNED\t${records.length}`, ''].join('\n');
  fs.writeFileSync(path.join(root, 'registry.tsv'), manifest(0, 1));
  for (let i = 0; i < 4; i++) {
    const dir = path.join(root, 'shards', String(i));
    fs.mkdirSync(path.join(dir, 'coverage'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'manifest.tsv'), manifest(i, 4));
    const owned = records.filter((_, n) => n % 4 === i);
    const tally = (kind) => owned.filter((s) => s.endsWith(`\t${kind}`)).length;
    fs.writeFileSync(path.join(dir, 'models.log'), owned.map((s) => s.replace('CHECK', 'RESULT'))
      .concat(`TALLY holds=${tally('holds')} caught=${tally('caught')} reached=${tally('reached')}`, '').join('\n'));
    for (const row of owned) {
      const [, , name, kind] = row.split('\t');
      if (kind === 'holds') fs.writeFileSync(path.join(dir, 'coverage', `${name}.log`), name);
    }
  }
  return {
    root,
    change(file, edit) {
      const target = path.join(root, file);
      fs.writeFileSync(target, edit(fs.readFileSync(target, 'utf8')));
    },
    run() {
      return spawnSync('python3', [path.resolve(__dirname, '../../formal/model_shards.py'),
        path.join(root, 'shards'), '--registry', path.join(root, 'registry.tsv'),
        '--out', path.join(root, 'models.log'), '--coverage', path.join(root, 'coverage')],
      { encoding: 'utf8' });
    },
  };
}

test('model shards merge to the complete registry and one real tally', (t) => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const merged = fs.readFileSync(path.join(f.root, 'models.log'), 'utf8');
  assert.equal((merged.match(/^TALLY /gm) ?? []).length, 1);
  assert.match(merged, /TALLY holds=3 caught=2 reached=2/);
  assert.deepEqual(fs.readdirSync(path.join(f.root, 'coverage')), ['check_0.log', 'check_3.log', 'check_6.log']);
});

for (const [name, plant] of [
  ['missing shard', (f) => fs.rmSync(path.join(f.root, 'shards/3'), { recursive: true })],
  ['missing result', (f) => f.change('shards/0/models.log', (s) => s.replace(/^RESULT.*\n/, ''))],
  ['duplicate result', (f) => f.change('shards/0/models.log', (s) => s + s.split('\n')[0] + '\n')],
  ['wrong shard', (f) => f.change('shards/0/models.log', (s) => s.replace('RESULT\t0\tcheck_0', 'RESULT\t1\tcheck_1'))],
  ['duplicate shard identity', (f) => f.change('shards/1/manifest.tsv', (s) => s.replace('SHARD\t1', 'SHARD\t0'))],
  ['invented tally', (f) => f.change('shards/0/models.log', (s) => s.replace('holds=1', 'holds=100'))],
  ['duplicate tally', (f) => f.change('shards/0/models.log', (s) => s + 'TALLY holds=1 caught=1 reached=0\n')],
  ['truncated registry', (f) => f.change('shards/0/manifest.tsv', (s) => s.replace(/PLANNED.*\n/, ''))],
  ['check omitted by every worker', (f) => {
    for (let i = 0; i < 4; i++) f.change(`shards/${i}/manifest.tsv`,
      (s) => s.replace('CHECK\t6\tcheck_6\tholds\n', '').replace('PLANNED\t7', 'PLANNED\t6'));
  }],
]) {
  test(`the model merge gate catches a planted ${name}`, (t) => {
    const f = fixture(t);
    plant(f);
    const result = f.run();
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stderr, /model shards:/);
  });
}
