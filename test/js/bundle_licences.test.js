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
