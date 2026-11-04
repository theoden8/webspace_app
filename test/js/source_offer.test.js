// LICENSE-003, LICENSE-004: a bundled library's notices carry the text of each
// licence it names, and the source they offer can be given. The copyright
// file is written by linux/install_notices.sh, read here as
// tool/check_source_offer.js and tool/check_bundle_licences.js read a built
// package, and the archive is a fake that holds what each case says; CI asks
// the real one about the real snap.

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

// libwpe's tree in small: BSD-2-Clause in its COPYING, and three headers whose
// licences it carries no text of: the LGPL, Apache-2.0, and X11-style notices
// after a generated-file comment.
const KEYSYMS_NOTICE = '/***********************************************************\n'
  + 'Copyright 1987, 1994, 1998  The Open Group\n\n'
  + 'Permission to use, copy, modify, distribute, and sell this software and its\n'
  + 'documentation for any purpose is hereby granted without fee, provided that\n'
  + 'the above copyright notice appear in all copies and that both that\n'
  + 'copyright notice and this permission notice appear in supporting\ndocumentation.\n\n'
  + 'Copyright 1987 by Digital Equipment Corporation, Maynard, Massachusetts\n'
  + '******************************************************************/\n';
const LIBWPE_TREE = {
  COPYING: 'Redistribution and use in source and binary forms, with or without modification, are permitted\n',
  'src/key-unicode.c': '/*\n * Copyright (C) 1995-1997 Peter Mattis, Spencer Kimball and Josh MacDonald\n'
    + ' *\n * This library is free software; you can redistribute it and/or modify it under the terms of the\n'
    + ' * GNU Lesser General Public License as published by the Free Software Foundation; either\n'
    + ' * version 2 of the License, or (at your option) any later version.\n */\n',
  'src/gamepad.c': '/*\n * Copyright 2020 RDK Management\n *\n'
    + ' * Licensed under the Apache License, Version 2.0 (the "License");\n */\n',
  'include/wpe/keysyms.h': '#ifndef wpe_keysyms_h\n\n/* This file is autogenerated. */\n' + KEYSYMS_NOTICE
    + '\n/* Copyright 2026 Someone, a later comment */\n#define WPE_KEY_VoidSymbol 0xffffff\n',
};
const LGPL_2 = '                  GNU LIBRARY GENERAL PUBLIC LICENSE\n                       Version 2, June 1991\n';
// The freedesktop SDK's copy: whitespace first, and https URLs.
const APACHE_2 = '\n  \n                                 Apache License\n                           Version 2.0, January 2004\n'
  + '                        https://www.apache.org/licenses/\n';
const GPL_2 = '                    GNU GENERAL PUBLIC LICENSE\n                       Version 2, June 1991\n';
const LIBWPE_LICENSE = 'BSD-2-clause and LGPL-2+ and Apache-2.0 and MIT-open-group and HPND';
const libwpe = { tree: LIBWPE_TREE, license: LIBWPE_LICENSE };
const texts = { 'LGPL-2': LGPL_2, LICENSE: APACHE_2 };
const withTexts = ['--licence-text', 'host/LGPL-2', '--licence-text', 'host/LICENSE'];

test('LICENSE-003 LICENSE-004 each licence the notices name travels with its text, and a header\'s notice with it', (t) => {
  const bare = notices(t, { revision: COMMIT, ...libwpe }).run;
  assert.equal(bare.status, 1, 'libwpe as it was: the LGPL named and no text of it');
  assert.match(bare.stderr, /--license names LGPL, and no licence file of \S+ is its text/);
  const lgplOnly = notices(t, { revision: COMMIT, ...libwpe, host: texts, extra: ['--licence-text', 'host/LGPL-2'] }).run;
  assert.equal(lgplOnly.status, 1, 'Apache-2.0 named and no text of it');
  assert.match(lgplOnly.stderr, /--license names Apache-2\.0, and no licence file of \S+ is its text/);

  const { root, run } = notices(t, {
    revision: COMMIT, ...libwpe, host: texts, extra: [...withTexts, '--notice-of', 'include/wpe/keysyms.h'],
  });
  assert.equal(run.status, 0, run.stderr);
  const doc = path.join(root, 'usr/share/doc/lib');
  const licences = (rel) => fs.readFileSync(path.join(doc, 'licences', rel), 'utf8');
  assert.equal(licences('LGPL-2'), LGPL_2, 'the LGPL beside the notices');
  assert.equal(licences('LICENSE'), APACHE_2, 'Apache-2.0 beside the notices, as the SDK words it');
  assert.equal(licences('include_wpe_keysyms.h.notice'), KEYSYMS_NOTICE,
    'the first comment that names a copyright, as it is, past the generated-file note');
  const copyright = fs.readFileSync(path.join(doc, 'copyright'), 'utf8');
  for (const line of [
    " licences/LGPL-2 is the build host's copy of a licence text the tree lacks (LGPL).",
    " licences/LICENSE is the build host's copy of a licence text the tree lacks (Apache-2.0).",
    ' licences/include_wpe_keysyms.h.notice is the notice include/wpe/keysyms.h carries in its header.',
    `License: ${LIBWPE_LICENSE}`,
  ]) assert.ok(copyright.split('\n').includes(line), `the copyright file lacks: ${line}`);
  for (const holder of ['Peter Mattis', 'RDK Management', 'The Open Group']) {
    assert.ok(licences('COPYRIGHT-HOLDERS.txt').includes(holder), `no copyright line of ${holder}`);
  }
  fs.mkdirSync(path.join(root, 'lib/debug/source/lib/src'), { recursive: true });
  fs.writeFileSync(path.join(root, 'lib/debug/source/lib/src/key-unicode.c'), LIBWPE_TREE['src/key-unicode.c']);
  assert.deepEqual(B.refusals(root), [], 'the notices pass, and so does the debug source they now cover');
});

test('LICENSE-003 a licence text is one --license names, and a notice is a header\'s', (t) => {
  const run = (extra, { license = LIBWPE_LICENSE, host = texts } = {}) =>
    notices(t, { revision: COMMIT, ...libwpe, license, host, extra: [...withTexts.slice(0, 2), ...extra] }).run;
  const refused = (r, status, message, why) => {
    assert.equal(r.status, status, `${why}: ${r.stderr}`);
    assert.match(r.stderr, message, why);
  };
  refused(run(['--licence-text', 'host/Apache-2.0']), 2, /--licence-text \S+\/host\/Apache-2\.0 is not a file/,
    'a text the build host does not have');
  refused(run(['--licence-text', 'host/GPL-2'], { host: { ...texts, 'GPL-2': GPL_2 } }), 2,
    /host\/GPL-2 is the text of neither an LGPL nor Apache-2\.0/, 'the GPL given as a licence text');
  refused(run(['--licence-text', 'host/LICENSE'], { license: 'BSD-2-clause and LGPL-2+' }), 2,
    /host\/LICENSE is the text of Apache-2\.0, which --license does not name/, 'a text of a licence the notices do not name');
  refused(run(['--licence-text', 'host/COPYING'], { host: { ...texts, COPYING: APACHE_2 } }), 1,
    /would replace the tree's \S+\/licences\/COPYING/, 'a text that would replace one of the tree');
  const notice = (rel, tree = {}) => notices(t, {
    revision: COMMIT, ...libwpe, tree: { ...LIBWPE_TREE, ...tree }, host: texts, extra: [...withTexts, '--notice-of', rel],
  }).run;
  refused(notice('../outside.h'), 2, /--notice-of \.\.\/outside\.h is not a path inside the tree/, 'a path out of the tree');
  refused(notice('/etc/hostname'), 2, /is not a path inside the tree/, 'an absolute path');
  refused(notice('include/wpe/absent.h'), 2, /--notice-of include\/wpe\/absent\.h is not a file of/, 'a file the tree lacks');
  refused(notice('src/bare.c', { 'src/bare.c': '/* a plain comment */\nint x;\n' }), 1,
    /--notice-of src\/bare\.c has no block comment that names a copyright/, 'a file whose comments name no copyright');
  refused(notice('src/held.c', { 'src/held.c': '/* Copyright 2026 Someone. All rights reserved. */\n' }), 1,
    /the notice in src\/held\.c names no licence/, 'a copyright with no licence beside it');
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
