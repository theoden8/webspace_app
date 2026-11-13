// PLATFORM-013: tool/appimage_signature.js, which scripts/release_appimage.sh
// runs on every AppImage it signs and the Snap workflow on one it signs with a
// throwaway key, caught on each mistake it is for. The file is an ELF with
// the sections an AppImage runtime carries, signed here as appimagetool signs.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const S = require('../../tool/appimage_signature');

const INFO = 'gh-releases-zsync|owner|repo|latest|App-*-x86_64.AppImage.zsync';

function have(cmd) {
  try {
    execFileSync(cmd, ['--version'], { stdio: 'ignore' });
    return true;
  } catch (e) {
    if (e instanceof Error && 'code' in e && e.code === 'ENOENT') return false;
    throw e;
  }
}

function tools(t) {
  const missing = ['gpg', 'objcopy'].filter((c) => !have(c));
  if (missing.length === 0) return true;
  if (process.env.CI === 'true') assert.fail(`${missing.join(' and ')} needed to sign a test AppImage`);
  t.skip(`no ${missing.join(' or ')}`);
  return false;
}

function gpg(home, args, input) {
  return execFileSync('gpg', ['--homedir', home, '--batch', '--no-tty', '--pinentry-mode', 'loopback', '--passphrase', '', ...args],
    { input, encoding: 'utf8' });
}

/** A key in a home of its own: { home, fpr, pub }. */
function key(t, name) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'appimage-key-'));
  fs.chmodSync(home, 0o700);
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  gpg(home, ['--quick-generate-key', name, 'ed25519', 'sign', '1d']);
  const fpr = gpg(home, ['--with-colons', '--list-keys', name]).split('\n').find((l) => l.startsWith('fpr:')).split(':')[9];
  return { home, fpr, pub: gpg(home, ['--armor', '--export', fpr]) };
}

/** An ELF with empty .sha256_sig, .sig_key and .upd_info sections, the last holding [info]. */
function appimage(t, info = INFO) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'appimage-file-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const pad = (name, size, content = '') => {
    const at = path.join(dir, name);
    const bytes = Buffer.alloc(size);
    bytes.write(content);
    fs.writeFileSync(at, bytes);
    return at;
  };
  const file = path.join(dir, 'App.AppImage');
  fs.copyFileSync(fs.realpathSync('/bin/true'), file);
  execFileSync('objcopy', [
    '--add-section', `.upd_info=${pad('upd', 1024, info)}`,
    '--add-section', `.sha256_sig=${pad('sig', 1024)}`,
    '--add-section', `.sig_key=${pad('key', 8192)}`,
    file,
  ]);
  return file;
}

/** Signs [file] with [k] as appimagetool does. */
function sign(file, k) {
  const buf = fs.readFileSync(file);
  const at = S.sections(buf);
  const signature = gpg(k.home, ['--armor', '--textmode', '--local-user', k.fpr, '--detach-sign'], S.signedDigest(buf, at));
  buf.write(signature, at.get('.sha256_sig').offset, 'latin1');
  buf.write(k.pub, at.get('.sig_key').offset, 'latin1');
  fs.writeFileSync(file, buf);
}

test('PLATFORM-013 an AppImage signed by the pinned key verifies', (t) => {
  if (!tools(t)) return;
  const k = key(t, 'release');
  const file = appimage(t);
  sign(file, k);
  assert.deepEqual(S.problems(file, { key: k.pub, updateInfo: INFO }), []);
});

test('PLATFORM-013 a byte changed after signing fails', (t) => {
  if (!tools(t)) return;
  const k = key(t, 'release');
  const file = appimage(t);
  sign(file, k);
  const buf = fs.readFileSync(file);
  buf[100] ^= 1;
  fs.writeFileSync(file, buf);
  assert.deepEqual(S.problems(file, { key: k.pub }), [`${file}: the signature does not verify against ${k.fpr}`]);
});

test('PLATFORM-013 a file signed by another key fails, whatever key it carries', (t) => {
  if (!tools(t)) return;
  const pinned = key(t, 'release');
  const other = key(t, 'other');
  const file = appimage(t);
  sign(file, other);
  assert.deepEqual(S.problems(file, { key: pinned.pub }), [
    `${file}: carries the key ${other.fpr}, not ${pinned.fpr}`,
    `${file}: the signature does not verify against ${pinned.fpr}`,
  ]);
});

test('PLATFORM-013 an unsigned file, or one pointing elsewhere for updates, fails', (t) => {
  if (!tools(t)) return;
  const k = key(t, 'release');
  const file = appimage(t, 'gh-releases-zsync|someone|else|latest|App-*.zsync');
  assert.deepEqual(S.problems(file, { key: k.pub, updateInfo: INFO }), [
    `${file}: update information is "gh-releases-zsync|someone|else|latest|App-*.zsync", not ${JSON.stringify(INFO)}`,
    `${file}: not signed`,
  ]);
});
