// LICENSE-004: a bundled LGPL library's notices carry the LGPL's text, and the
// source they offer can be given. The copyright file is written by
// linux/install_notices.sh, read here as tool/check_source_offer.js and
// tool/check_bundle_licences.js read a built package, and the archive is a fake
// that holds what each case says; CI asks the real one about the real snap.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');
const S = require('../../tool/check_source_offer');
const B = require('../../tool/check_bundle_licences');

const COMMIT = 'c22ba3278caac6a1fc8b0c7a10f04db1ffc44982';
const TREE = 'c4057731cd96fd3b00c2c5d53e7f0c5c34c90671';
const SOURCE = 'https://github.com/WebKit/WebKit.git';

const WEBKIT_TREE = {
  COPYING: 'GNU LESSER GENERAL PUBLIC LICENSE\n',
  'a.c': '/* Copyright (C) 2026 Someone */\n',
};

// The notices of [tree] as linux/install_notices.sh writes them; each of
// [host] is a file outside the tree, passed by its name.
function notices(t, { revision, offer = true, changed = null, tree = WEBKIT_TREE, license = 'LGPL-2.1+', host = {}, extra = [] }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'source-offer-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const src = path.join(root, 'src');
  for (const [rel, text] of Object.entries(tree)) {
    fs.mkdirSync(path.dirname(path.join(src, rel)), { recursive: true });
    fs.writeFileSync(path.join(src, rel), text);
  }
  fs.mkdirSync(path.join(root, 'host'));
  for (const [name, text] of Object.entries(host)) fs.writeFileSync(path.join(root, 'host', name), text);
  const args = [path.join(REPO, 'linux/install_notices.sh'), '--src', src,
    '--dest', path.join(root, 'pkg/usr/share/doc/lib'), '--name', 'lib', '--source', SOURCE,
    '--revision', revision, '--license', license, ...(offer ? ['--offer'] : []),
    ...(changed ? ['--changed', changed] : []),
    ...extra.map((a) => a.replace(/^host\//, `${root}/host/`))];
  const run = spawnSync('bash', args, { encoding: 'utf8' });
  return { root: path.join(root, 'pkg'), run };
}

const archive = (held) => async (url) => held[url.replace('https://archive.softwareheritage.org/api/1', '')] ?? null;

test('LICENSE-004 the offer names the commit the library was built from', (t) => {
  const { root, run } = notices(t, { revision: COMMIT });
  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(S.offers(root), [{ file: 'usr/share/doc/lib/copyright', source: SOURCE, revision: COMMIT }]);
  assert.deepEqual(S.offers(notices(t, { revision: COMMIT, offer: false }).root), [], 'no offer, nothing to give');
  const changed = notices(t, { revision: COMMIT, changed: 'fonts replaced' }).root;
  assert.deepEqual(S.offers(changed), [{ file: 'usr/share/doc/lib/copyright', source: SOURCE, revision: COMMIT }],
    'a build that changed the tree still names its commit');
  assert.match(fs.readFileSync(path.join(changed, 'usr/share/doc/lib/copyright'), 'utf8'),
    /^Comment: Built from \S+ at [0-9a-f]{40}, changed before the build:\n fonts replaced\.$/m,
    'and says what changed, never "as it is"');
  const branch = notices(t, { revision: 'main' }).run;
  assert.equal(branch.status, 2, 'an offer of a branch, which moves, is refused as the notices are written');
  assert.match(branch.stderr, /--offer needs --revision to be a commit/);
});

// libwpe's tree: BSD-2-Clause in its COPYING, and one source file under the
// LGPL that carries no text of it.
const LIBWPE_TREE = {
  COPYING: 'Redistribution and use in source and binary forms, with or without modification, are permitted\n',
  'src/key-unicode.c': '/*\n * Copyright (C) 1995-1997 Peter Mattis, Spencer Kimball and Josh MacDonald\n'
    + ' *\n * This library is free software; you can redistribute it and/or modify it under the terms of the\n'
    + ' * GNU Lesser General Public License as published by the Free Software Foundation; either\n'
    + ' * version 2 of the License, or (at your option) any later version.\n */\n',
};
const LGPL_2 = '                  GNU LIBRARY GENERAL PUBLIC LICENSE\n                       Version 2, June 1991\n';
const GPL_2 = '                    GNU GENERAL PUBLIC LICENSE\n                       Version 2, June 1991\n';
const libwpe = { tree: LIBWPE_TREE, license: 'BSD-2-clause and LGPL-2+' };

test('LICENSE-004 an LGPL the notices name travels with its text', (t) => {
  const bare = notices(t, { revision: COMMIT, ...libwpe }).run;
  assert.equal(bare.status, 1, 'libwpe as it was: the LGPL named and no text of it');
  assert.match(bare.stderr, /--license names an LGPL, and no licence file of \S+ is its text/);

  const { root, run } = notices(t, { revision: COMMIT, ...libwpe, host: { 'LGPL-2': LGPL_2 }, extra: ['--lgpl-text', 'host/LGPL-2'] });
  assert.equal(run.status, 0, run.stderr);
  const doc = path.join(root, 'usr/share/doc/lib');
  assert.equal(fs.readFileSync(path.join(doc, 'licences/LGPL-2'), 'utf8'), LGPL_2, 'the text beside the notices');
  const copyright = fs.readFileSync(path.join(doc, 'copyright'), 'utf8');
  assert.match(copyright, /^ licences\/LGPL-2 is the build host's text of the GNU LGPL, which the tree names but does not carry\.$/m);
  assert.match(copyright, /^License: BSD-2-clause and LGPL-2\+$/m);
  assert.match(fs.readFileSync(path.join(doc, 'licences/COPYRIGHT-HOLDERS.txt'), 'utf8'), /Peter Mattis/);
  fs.mkdirSync(path.join(root, 'lib/debug/source/lib/src'), { recursive: true });
  fs.writeFileSync(path.join(root, 'lib/debug/source/lib/src/key-unicode.c'), LIBWPE_TREE['src/key-unicode.c']);
  assert.deepEqual(B.refusals(root), [], 'the notices pass, and so does the debug source they now cover');

  const lgplText = (host, name) => notices(t, { revision: COMMIT, ...libwpe, host, extra: ['--lgpl-text', `host/${name}`] }).run;
  const missing = lgplText({}, 'LGPL-2');
  assert.equal(missing.status, 2, 'a text the build host does not have');
  assert.match(missing.stderr, /--lgpl-text \S+\/host\/LGPL-2 is not a file/);
  const gpl = lgplText({ 'GPL-2': GPL_2 }, 'GPL-2');
  assert.equal(gpl.status, 2, 'the GPL given as the LGPL');
  assert.match(gpl.stderr, /is not the text of a GNU Lesser or Library General Public License/);
  const clash = lgplText({ COPYING: LGPL_2 }, 'COPYING');
  assert.equal(clash.status, 1, 'a text that would replace one of the tree');
  assert.match(clash.stderr, /would replace the tree's \S+\/licences\/COPYING/);
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
