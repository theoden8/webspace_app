// LICENSE-001 and LICENSE-004 on a built package's files, as the snap and the
// flatpak jobs run scripts/verify_webkit_shipped.sh: a stub libwpe, a stub
// WebKit that links it and an app that links WebKit, built here with cc under
// a root that is a symlink, as a snap's /snap/<name>/current is.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { REPO } = require('./helpers/source');

const cc = spawnSync('cc', ['--version']).status === 0;
const needsCc = { skip: cc || process.env.CI === 'true' ? false : 'no cc on PATH' };

function pkg(t, { fonts = 'Licensed under the SIL Open Font License', links = true, wpe = true, wpeLinked = true, debug = false }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'webkit-shipped-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const lib = path.join(dir, 'rev/usr/lib/x/libWPEWebKit-2.0.so.1.0');
  const wpeLib = path.join(dir, wpe ? 'rev/usr/lib/x/libwpe-1.0.so.1.0' : 'elsewhere/libwpe-1.0.so.1.0');
  fs.mkdirSync(path.dirname(lib), { recursive: true });
  fs.mkdirSync(path.dirname(wpeLib), { recursive: true });
  fs.mkdirSync(path.join(dir, 'rev/opt/webspace/lib'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'wpe.c'), 'int wpe(void) { return 0; }\n');
  fs.writeFileSync(path.join(dir, 'wk.c'), wpeLinked ? 'int wpe(void);\nint wk(void) { return wpe(); }\n' : 'int wk(void) { return 0; }\n');
  fs.writeFileSync(path.join(dir, 'app.c'), links ? 'int wk(void);\nint main(void) { return wk(); }\n' : 'int main(void) { return 0; }\n');
  const build = (args) => assert.equal(spawnSync('cc', args, { cwd: dir }).status, 0, `cc ${args.join(' ')}`);
  build(['-shared', '-fPIC', '-o', wpeLib, '-Wl,-soname,libwpe-1.0.so.1', 'wpe.c']);
  fs.symlinkSync(path.basename(wpeLib), path.join(path.dirname(wpeLib), 'libwpe-1.0.so.1'));
  build(['-shared', '-fPIC', '-o', lib, '-Wl,-soname,libWPEWebKit-2.0.so.1', 'wk.c', ...(wpeLinked ? [wpeLib] : [])]);
  build(['-o', 'rev/opt/webspace/webspace_app', 'app.c', `-Wl,-rpath-link,${path.dirname(wpeLib)}`, ...(links ? [lib] : [])]);
  fs.appendFileSync(lib, fonts);
  if (debug) {
    // flatpak-builder's split debug info: an ELF of the same name, no fonts.
    const at = path.join(dir, 'rev/lib/debug/usr/lib/x');
    fs.mkdirSync(at, { recursive: true });
    fs.copyFileSync(wpeLib, path.join(at, `${path.basename(wpeLib)}.debug`));
    fs.copyFileSync(wpeLib, path.join(at, `${path.basename(lib)}.debug`));
  }
  fs.symlinkSync('rev', path.join(dir, 'current'));
  return path.join(dir, 'current');
}

const run = (root) => spawnSync('bash', [path.join(REPO, 'scripts/verify_webkit_shipped.sh'), root, 'opt/webspace'],
  { encoding: 'utf8' });

test('LICENSE-004 a WebKit the app loads, with PDF.js\'s OFL fonts, passes under a symlinked root', needsCc, (t) => {
  const r = run(pkg(t, {}));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /usr\/lib\/x\/libWPEWebKit-2\.0\.so\.1\.0\) is a shared library of its own, loaded by opt\/webspace\/webspace_app/);
  assert.match(r.stdout, /usr\/lib\/x\/libwpe-1\.0\.so\.1\.0\) is a shared library of its own, loaded by usr\/lib\/x\/libWPEWebKit-2\.0\.so\.1\.0/);
});

test("LICENSE-004 a flatpak's split debug info is not a library the check holds", needsCc, (t) => {
  const r = run(pkg(t, { debug: true }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^WebKit \(usr\/lib\/x\/libWPEWebKit-2\.0\.so\.1\.0\) /m, 'the debug file read as a WebKit');
  assert.match(r.stdout, /^libwpe \(usr\/lib\/x\/libwpe-1\.0\.so\.1\.0\) /m, 'the debug file read as a libwpe');
});

test('LICENSE-001 the check refuses GPL fonts, missing OFL ones, and a WebKit or libwpe nothing loads', needsCc, (t) => {
  const refused = (opts, pattern, why) => {
    const r = run(pkg(t, opts));
    assert.equal(r.status, 1, `${why}: exit ${r.status}`);
    assert.match(r.stderr, pattern, why);
  };
  refused({ fonts: 'Licensed under the SIL Open Font License Licensed under the Liberation Fonts license' },
    /carries Liberation 1\.x, under GPL-2\.0/, 'a 1.x font beside the OFL one');
  refused({ fonts: '' }, /carries no PDF\.js font of the OFL release/, 'no OFL font');
  refused({ links: false }, /nothing in .* loads WebKit as a shared library/, 'linked in, or not loaded');
  refused({ wpe: false }, /carries no libwpe-1\.0\.so of its own/, 'no libwpe in the package');
  refused({ wpeLinked: false }, /nothing in .* loads libwpe as a shared library/, 'libwpe linked in, or not loaded');
});
