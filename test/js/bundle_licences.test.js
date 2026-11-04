// LICENSE-001 over a built Linux package (tool/check_bundle_licences.js, run
// by CI on the Linux bundle and the snap it builds): each rule caught on the
// mistake it is for, on packages laid out here; the real ones are checked
// where CI builds them.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const B = require('../../tool/check_bundle_licences');
const L = require('./helpers/licences');
const { read } = require('./helpers/source');

function pkg(t, files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bundle-licences-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), text);
  }
  return root;
}

const dep5 = (...stanzas) => ['Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/', '',
  ...stanzas.flatMap(([files, licence]) => [`Files: ${files}`, 'Copyright: someone', `License: ${licence}`, ''])].join('\n');

test('LICENSE-001 a staged package under the GPL is refused, an LGPL one shared is not', (t) => {
  const root = pkg(t, {
    'usr/share/doc/libfine/copyright': dep5(['*', 'LGPL-2.1+'], ['src/x.c', 'Expat']),
    'usr/share/doc/libbad/copyright': dep5(['*', 'BSD-3-clause'], ['src/core.c', 'GPL-2+']),
  });
  assert.deepEqual(B.refusals(root), ['usr/share/doc/libbad/copyright: GPL-2.0-or-later']);
});

test("LICENSE-001 a package's build-only row covers only the stanza it lists", (t) => {
  const table = B.names([
    'GPL-2+\tGPL-2.0-or-later',
    'Expat\tMIT',
    'GPL-2+\tLicenseRef-build-only\tlibevent-2.1-7t64\tm4/libtool.m4\tlibtool\'s macros',
  ].join('\n'));
  const licences = new Map([
    ['MIT', { how: 'linked', only: null }],
    ['LicenseRef-build-only', { how: 'linked', only: new Set(['deb:libevent-2.1-7t64']) }],
  ]);
  const build = pkg(t, { 'opt/lib/tor/docs/libevent-2.1-7t64.txt': dep5(['*', 'Expat'], ['m4/libtool.m4', 'GPL-2+']) });
  assert.deepEqual(B.refusals(build, { table, licences }), [], 'the build macro the row names');
  const widened = pkg(t, { 'opt/lib/tor/docs/libevent-2.1-7t64.txt': dep5(['m4/libtool.m4 event.c', 'GPL-2+']) });
  assert.deepEqual(B.refusals(widened, { table, licences }),
    ['opt/lib/tor/docs/libevent-2.1-7t64.txt: GPL-2.0-or-later'], 'a library file in the same stanza');
  const other = pkg(t, { 'usr/share/doc/libother/copyright': dep5(['m4/libtool.m4', 'GPL-2+']) });
  assert.deepEqual(B.refusals(other, { table, licences }),
    ['usr/share/doc/libother/copyright: GPL-2.0-or-later'], 'another package');
});

test('LICENSE-001 a name no row reads, or a file that is not machine-readable, is refused', (t) => {
  const root = pkg(t, {
    'usr/share/doc/libnew/copyright': dep5(['*', 'SSPL-1.0']),
    'usr/share/doc/libold/copyright': 'This package was debianized by someone.\nIt is GPL.\n',
  });
  assert.deepEqual(B.refusals(root), [
    'usr/share/doc/libnew/copyright: SSPL-1.0 is a name openspec/specs/legal/debian_licences.tsv does not read',
    'usr/share/doc/libold/copyright: (not a machine-readable copyright file) is a name openspec/specs/legal/debian_licences.tsv does not read',
  ]);
});

test("LICENSE-001 the programs' notices beside tor are not read as a library's", (t) => {
  const root = pkg(t, {
    'opt/lib/tor/docs/tor.txt': 'Copyright (c) the Tor Project\nRedistribution and use ...\n',
    'opt/lib/tor/docs/lyrebird.txt': 'lyrebird: its own program\n\n--- LICENSE\n\nBSD 2-Clause\n',
    'opt/lib/tor/docs/libevent-2.1-7t64.txt': 'Not a machine-readable copyright file.\n',
  });
  assert.deepEqual(B.refusals(root), ['opt/lib/tor/docs/libevent-2.1-7t64.txt: (not a machine-readable copyright file) '
    + 'is a name openspec/specs/legal/debian_licences.tsv does not read']);
});

test('LICENSE-001 a shipped file carrying a GNU notice is refused, a notice under doc/ is not', (t) => {
  const notice = 'This program is free software; you can redistribute it under the terms of the GNU General\n'
    + '# Public License as published by the Free Software Foundation.\n';
  const root = pkg(t, {
    'usr/share/doc/libfine/copyright': dep5(['*', 'Expat']),
    'usr/share/doc/libfine/README': notice,
    'usr/lib/helper.sh': notice,
  });
  assert.deepEqual(B.refusals(root), ["usr/lib/helper.sh: carries a GNU licence's notice"]);
});

// libwpe's src/key-unicode.c header, adapted from GDK's gdkkeyuni.c.
const LGPL_NOTICE = ` * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library. If not, see <http://www.gnu.org/licenses/>.
`;
const GPL_NOTICE = LGPL_NOTICE.replaceAll('GNU Lesser General Public\n *', 'GNU General Public\n *');
const KEY_UNICODE = 'lib/debug/source/libwpe/src/key-unicode.c';

test("LICENSE-001 a flatpak's debug source under the LGPL passes once its library's notices name the LGPL", (t) => {
  const before = pkg(t, { 'share/doc/libwpe/copyright': dep5(['*', 'BSD-2-clause']), [KEY_UNICODE]: LGPL_NOTICE });
  assert.deepEqual(B.refusals(before), [`${KEY_UNICODE}: carries a GNU licence's notice`],
    'libwpe as it was: its notices name no LGPL');
  const lgpl = dep5(['*', 'BSD-2-clause and LGPL-2+']);
  assert.deepEqual(B.refusals(pkg(t, { 'share/doc/libwpe/copyright': lgpl, [KEY_UNICODE]: LGPL_NOTICE })), []);
  assert.deepEqual(B.refusals(pkg(t, { 'usr/share/doc/libwpe/copyright': lgpl, [KEY_UNICODE]: LGPL_NOTICE })), [],
    'notices where a snap keeps them');
});

test('LICENSE-001 a debug source is let through only under the LGPL, and only its own library\'s', (t) => {
  const lgpl = dep5(['*', 'BSD-2-clause and LGPL-2+']);
  assert.deepEqual(B.refusals(pkg(t, { 'share/doc/libwpe/copyright': lgpl, [KEY_UNICODE]: GPL_NOTICE })),
    [`${KEY_UNICODE}: carries a GNU licence's notice`], 'a GPL notice in a debug source');
  assert.deepEqual(B.refusals(pkg(t, { 'share/doc/libwpe/copyright': lgpl, [KEY_UNICODE]: LGPL_NOTICE + GPL_NOTICE })),
    [`${KEY_UNICODE}: carries a GNU licence's notice`], 'the GPL named beside the LGPL');
  const other = 'lib/debug/source/libother/a.c';
  assert.deepEqual(B.refusals(pkg(t, { 'share/doc/libwpe/copyright': lgpl, [other]: LGPL_NOTICE })),
    [`${other}: carries a GNU licence's notice`], 'a debug source of a library with no notices');
  assert.deepEqual(B.refusals(pkg(t, {
    'share/doc/libwpe/copyright': lgpl, 'share/doc/libother/copyright': dep5(['*', 'Expat']), [other]: LGPL_NOTICE,
  })), [`${other}: carries a GNU licence's notice`], 'another library\'s LGPL does not cover it');
  assert.deepEqual(B.refusals(pkg(t, { 'share/doc/libwpe/copyright': lgpl, 'lib/libwpe/key-unicode.c': LGPL_NOTICE })),
    ["lib/libwpe/key-unicode.c: carries a GNU licence's notice"], 'an LGPL source shipped outside the debug sources');
  assert.deepEqual(B.refusals(pkg(t, { 'share/doc/libwpe/copyright': lgpl, [`opt/${KEY_UNICODE}`]: LGPL_NOTICE })),
    [`opt/${KEY_UNICODE}: carries a GNU licence's notice`], 'a debug source tree below the root');
});

// libwpe's licences: its COPYING, key-unicode.c's LGPL, gamepad.c's Apache-2.0,
// and keysyms.h's X11 notices, The Open Group's and Digital's.
test("LICENSE-001 libwpe's notices name licences the tables read and let ship", (t) => {
  const root = pkg(t, { 'usr/share/doc/libwpe/copyright': dep5(['*', 'BSD-2-clause and LGPL-2+ and Apache-2.0 and MIT-open-group and HPND']) });
  assert.deepEqual(B.refusals(root), []);
  const rows = read(B.NAMES);
  for (const name of ['MIT-open-group', 'HPND']) {
    const table = B.names(rows.replace(new RegExp(`^${name}\\t${name}\\n`, 'm'), ''));
    assert.deepEqual(B.refusals(root, { table }),
      [`usr/share/doc/libwpe/copyright: ${name} is a name ${B.NAMES} does not read`], `${name} unread`);
    const licences = L.policy();
    licences.delete(name);
    assert.deepEqual(B.refusals(root, { licences }),
      ['usr/share/doc/libwpe/copyright: BSD-2-Clause AND LGPL-2.0-or-later AND Apache-2.0 AND MIT-open-group AND HPND'],
      `${name} not allowed`);
  }
});

test('every build-only row names the files it covers and why (LICENSE-001)', () => {
  const rows = B.names();
  assert.ok(rows.length > 20, `${B.NAMES} read no rows`);
  for (const r of rows.filter((x) => x.spdx === 'LicenseRef-build-only')) {
    assert.ok(r.pkg && r.files.length, `${r.name} maps to LicenseRef-build-only without a package and its files`);
  }
});

test('LICENSE-001 CI checks the Linux bundle and the snap it builds', () => {
  const workflow = read('.github/workflows/build-and-test.yml');
  const build = workflow.indexOf('fvm flutter build linux --release');
  const check = workflow.indexOf('node tool/check_bundle_licences.js build/linux/x64/release/bundle');
  assert.ok(build >= 0 && check > build, 'CI does not check the Linux bundle after it builds it');
  assert.match(read('.github/workflows/snap.yml'), /node tool\/check_bundle_licences\.js /,
    'CI does not check the snap it builds');
});
