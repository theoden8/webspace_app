// LICENSE-004: the source a bundled LGPL library's notices offer can be given.
// The copyright file is written by linux/install_notices.sh, read here as
// tool/check_source_offer.js reads a built package, and the archive is a fake
// that holds what each case says; CI asks the real one about the real snap.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');
const S = require('../../tool/check_source_offer');

const COMMIT = 'c22ba3278caac6a1fc8b0c7a10f04db1ffc44982';
const TREE = 'c4057731cd96fd3b00c2c5d53e7f0c5c34c90671';
const SOURCE = 'https://github.com/WebKit/WebKit.git';

function notices(t, { revision, offer = true }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'source-offer-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const src = path.join(root, 'src');
  fs.mkdirSync(src);
  fs.writeFileSync(path.join(src, 'COPYING'), 'GNU LESSER GENERAL PUBLIC LICENSE\n');
  fs.writeFileSync(path.join(src, 'a.c'), '/* Copyright (C) 2026 Someone */\n');
  const args = [path.join(REPO, 'linux/install_notices.sh'), '--src', src,
    '--dest', path.join(root, 'pkg/usr/share/doc/lib'), '--name', 'lib', '--source', SOURCE,
    '--revision', revision, '--license', 'LGPL-2.1+', ...(offer ? ['--offer'] : [])];
  const run = spawnSync('bash', args, { encoding: 'utf8' });
  return { root: path.join(root, 'pkg'), run };
}

const archive = (held) => async (url) => held[url.replace('https://archive.softwareheritage.org/api/1', '')] ?? null;

test('LICENSE-004 the offer names the commit the library was built from', (t) => {
  const { root, run } = notices(t, { revision: COMMIT });
  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(S.offers(root), [{ file: 'usr/share/doc/lib/copyright', source: SOURCE, revision: COMMIT }]);
  assert.deepEqual(S.offers(notices(t, { revision: COMMIT, offer: false }).root), [], 'no offer, nothing to give');
  const branch = notices(t, { revision: 'main' }).run;
  assert.equal(branch.status, 2, 'an offer of a branch, which moves, is refused as the notices are written');
  assert.match(branch.stderr, /--offer needs --revision to be a commit/);
});

test('LICENSE-004 an offered source is one Software Heritage holds, with its tree', async (t) => {
  const offer = S.offers(notices(t, { revision: COMMIT }).root)[0];
  const held = { [`/revision/${COMMIT}/`]: { directory: TREE }, [`/directory/${TREE}/`]: [{ name: 'Source' }] };
  assert.deepEqual(await S.refusals(offer, { getJson: archive(held) }), []);
  assert.match((await S.refusals(offer, { getJson: archive({}) }))[0], /Software Heritage does not hold c22ba327/,
    'a commit the archive never took');
  assert.match((await S.refusals(offer, { getJson: archive({ [`/revision/${COMMIT}/`]: { directory: TREE } }) }))[0],
    /holds c22ba327\w+ but not its tree/, 'a commit without its tree');
  assert.match((await S.refusals({ ...offer, revision: 'main' }, { getJson: archive(held) }))[0],
    /not a commit an archive keeps/, 'a copyright file edited to name a branch');
});

test('LICENSE-004 CI asks the archive about the snap it built', () => {
  const workflow = read('.github/workflows/snap.yml');
  const install = workflow.indexOf('- name: Install the snap');
  const check = workflow.indexOf('node tool/check_source_offer.js "/snap/$snap_name/current"');
  assert.ok(install >= 0 && check > install, 'CI does not check the installed snap\'s offer');
  for (const trigger of workflow.match(/^ {4}paths:\n(?: {6}- .*\n)+/gm) ?? []) {
    assert.match(trigger, /- tool\/check_source_offer\.js/, 'a change to the check does not run the snap job');
  }
  assert.equal(execFileSync('node', ['-e', 'console.log(typeof fetch)'], { encoding: 'utf8' }).trim(), 'function');
});
