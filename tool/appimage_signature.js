#!/usr/bin/env node
// Verifies the signature appimagetool embeds in an AppImage (PLATFORM-013)
// against the release key the repository pins, not against the key the file
// carries: the signature in .sha256_sig is a detached OpenPGP signature of the
// hex SHA-256 of the file with .sha256_sig and .sig_key zeroed, as
// appimagetool 1.9.1 computes it before it fills them; the key in .sig_key,
// which AppImageUpdate holds an update to, must be the pinned key too; and
// .upd_info, when asked, must say where updates come from. Uses gpg in a home
// of its own, so the user's keyring is neither read nor changed.
//
//   node tool/appimage_signature.js FILE --key PUBLIC_KEY.asc [--update-info STRING]

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

/** The ELF64 little-endian file's sections by name: { offset, size }. */
function sections(buf) {
  if (buf.readUInt32BE(0) !== 0x7f454c46) throw new Error('not an ELF file');
  if (buf[4] !== 2 || buf[5] !== 1) throw new Error('not a 64-bit little-endian ELF file');
  const shoff = Number(buf.readBigUInt64LE(0x28));
  const shentsize = buf.readUInt16LE(0x3a);
  const shnum = buf.readUInt16LE(0x3c);
  const shstrndx = buf.readUInt16LE(0x3e);
  const header = (i) => {
    const at = shoff + i * shentsize;
    return { name: buf.readUInt32LE(at), offset: Number(buf.readBigUInt64LE(at + 0x18)), size: Number(buf.readBigUInt64LE(at + 0x20)) };
  };
  const strings = header(shstrndx);
  const out = new Map();
  for (let i = 0; i < shnum; i++) {
    const h = header(i);
    const start = strings.offset + h.name;
    const name = buf.subarray(start, buf.indexOf(0, start)).toString('latin1');
    out.set(name, { offset: h.offset, size: h.size });
  }
  return out;
}

/** A section's bytes up to its first NUL. */
function text(buf, s) {
  const bytes = buf.subarray(s.offset, s.offset + s.size);
  const end = bytes.indexOf(0);
  return bytes.subarray(0, end < 0 ? bytes.length : end);
}

/** The hex SHA-256 appimagetool signs: the file with .sha256_sig and .sig_key zeroed. */
function signedDigest(buf, at = sections(buf)) {
  const copy = Buffer.from(buf);
  for (const name of ['.sha256_sig', '.sig_key']) {
    const s = at.get(name);
    if (!s) throw new Error(`no ${name} section`);
    copy.fill(0, s.offset, s.offset + s.size);
  }
  return crypto.createHash('sha256').update(copy).digest('hex');
}

function gpg(home, args, { input } = {}) {
  return execFileSync('gpg', ['--homedir', home, '--batch', '--no-tty', ...args],
    { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
}

/** The primary key fingerprints in armored [key]. */
function fingerprints(home, key) {
  return gpg(home, ['--with-colons', '--show-keys'], { input: key })
    .split('\n').reduce((out, line, i, lines) => {
      if (line.startsWith('pub:')) {
        const fpr = lines.slice(i + 1).find((l) => l.startsWith('fpr:'));
        if (fpr) out.push(fpr.split(':')[9]);
      }
      return out;
    }, []);
}

/** What is wrong with [file]'s signature against armored [key], as lines; none when it verifies. */
function problems(file, { key, updateInfo = null }) {
  const buf = fs.readFileSync(file);
  const at = sections(buf);
  for (const name of ['.sha256_sig', '.sig_key', '.upd_info']) {
    if (!at.has(name)) return [`${file}: no ${name} section; not an AppImage of type 2`];
  }
  const out = [];
  const signature = text(buf, at.get('.sha256_sig'));
  const embedded = text(buf, at.get('.sig_key'));
  const info = text(buf, at.get('.upd_info')).toString('utf8');
  if (updateInfo !== null && info !== updateInfo) out.push(`${file}: update information is ${JSON.stringify(info)}, not ${JSON.stringify(updateInfo)}`);
  if (signature.length === 0) return [...out, `${file}: not signed`];

  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'appimage-signature-'));
  fs.chmodSync(home, 0o700);
  try {
    const pinned = fingerprints(home, key);
    if (pinned.length !== 1) return [...out, `the pinned key holds ${pinned.length} primary keys, not one`];
    const carried = embedded.length ? fingerprints(home, embedded) : [];
    if (carried.length !== 1 || carried[0] !== pinned[0]) {
      out.push(`${file}: carries the key ${carried.join(', ') || '(none)'}, not ${pinned[0]}`);
    }
    gpg(home, ['--import'], { input: key });
    const data = path.join(home, 'digest');
    const sig = path.join(home, 'digest.asc');
    fs.writeFileSync(data, signedDigest(buf, at));
    fs.writeFileSync(sig, signature);
    let status = '';
    try {
      status = gpg(home, ['--status-fd', '1', '--verify', sig, data]);
    } catch (e) {
      if (!(e instanceof Error && 'status' in e)) throw e;
      status = String(e.stdout ?? '');
    }
    const valid = status.split('\n').find((l) => l.startsWith('[GNUPG:] VALIDSIG '));
    if (!valid) out.push(`${file}: the signature does not verify against ${pinned[0]}`);
    else if (valid.split(' ')[11] !== pinned[0]) out.push(`${file}: signed by ${valid.split(' ')[11]}, not ${pinned[0]}`);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
  return out;
}

module.exports = { sections, signedDigest, fingerprints, problems };

if (require.main === module) {
  const args = process.argv.slice(2);
  const take = (flag) => {
    const i = args.indexOf(flag);
    return i < 0 ? null : args.splice(i, 2)[1];
  };
  const keyFile = take('--key');
  const updateInfo = take('--update-info');
  const [file] = args;
  if (!file || !keyFile || args.length !== 1) {
    console.error('usage: node tool/appimage_signature.js FILE --key PUBLIC_KEY.asc [--update-info STRING]');
    process.exit(2);
  }
  const found = problems(file, { key: fs.readFileSync(keyFile, 'utf8'), updateInfo });
  for (const line of found) console.error(`::error::${line}`);
  if (found.length) process.exit(1);
  console.log(`OK: ${file} is signed by the key in ${keyFile}`);
}
