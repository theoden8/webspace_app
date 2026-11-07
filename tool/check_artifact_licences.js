#!/usr/bin/env node
// LICENSE-001 and LICENSE-002 over a built APK, IPA or macOS app, unpacked,
// as tool/check_bundle_licences.js holds a Linux package: no file carries a
// GNU licence's notice, read from a text file's text, from a binary's
// printable strings and from the base64 runs in either, decoded; no binary
// names a file or package go/iptproxy/build.sh deletes from lyrebird, which a
// Go binary keeps by path; and no file is a copy of copyleft data the app
// downloads. The app's own credits, byte for byte the checkout's
// assets/licenses and assets/native_notices, are the one exemption.
//
//   node tool/check_artifact_licences.js <unpacked APK, IPA or .app>

const fs = require('node:fs');
const path = require('node:path');
const L = require('../test/js/helpers/licences');
const { REPO, read } = require('../test/js/helpers/source');

const BUILD_SH = 'go/iptproxy/build.sh';

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * What build.sh's GPL_PATHS deletes from lyrebird, as a Go binary names it:
 * a package by its import path, a file by its path in the module, versioned.
 * The licence text among them is no code.
 */
function goGplPaths(text = read(BUILD_SH)) {
  const list = text.match(/^GPL_PATHS='([^']*)'/m)?.[1];
  if (!list) throw new Error(`${BUILD_SH} names no GPL_PATHS`);
  return list.split(/\s+/).filter((p) => p && !/\.txt$/.test(p))
    .map((p) => ({ path: p, re: new RegExp(`lyrebird(?:@[^/\\s]+)?/${escape(p)}(?![\\w-])`) }));
}

/** A binary's printable runs, a JSON-escaped newline in one read as a newline. */
const stringsOf = (buf) => (buf.toString('latin1').match(/[\x20-\x7e\t\n\r]{20,}/g) ?? [])
  .map((s) => s.replace(/\\n/g, '\n'));

/** What the base64 runs in [text] decode to, from each offset a run may start at. */
function decoded(text) {
  const out = [];
  for (const [run] of text.matchAll(/[A-Za-z0-9+/]{200,}={0,2}/g)) {
    for (let k = 0; k < 4; k++) out.push(Buffer.from(run.slice(k), 'base64').toString('latin1'));
  }
  return out;
}

// The app's credits, where a Flutter build copies its assets.
const CREDIT = /(?:^|\/)flutter_assets\/(assets\/(?:licenses|native_notices)\/.+)$/;

/** Whether [file] at [rel] is one of the checkout's credits, unchanged. */
function isCredit(rel, file, repo) {
  const own = rel.match(CREDIT)?.[1];
  if (!own || !fs.existsSync(path.join(repo, own))) return false;
  return fs.readFileSync(path.join(repo, own)).equals(fs.readFileSync(file));
}

/** What [buf], shipped at [rel], carries that LICENSE-001 or LICENSE-002 refuses, one line each. */
function findingsIn(buf, { rel, goPaths }) {
  const out = new Set();
  const binary = buf.subarray(0, 8000).includes(0);
  const texts = binary ? stringsOf(buf) : [buf.toString('utf8')];
  for (const t of texts) {
    if (L.gnuNotice(t)) out.add(`${rel}: carries a GNU licence's notice`);
    for (const name of L.copyleftDataIn(t)) out.add(`${rel}: carries a copy of ${name}`);
    for (const d of decoded(t)) {
      if (L.gnuNotice(d)) out.add(`${rel}: carries a GNU licence's notice, base64-encoded`);
      for (const name of L.copyleftDataIn(d)) out.add(`${rel}: carries a copy of ${name}, base64-encoded`);
    }
  }
  if (binary) {
    const all = buf.toString('latin1');
    for (const { path: p, re } of goPaths) {
      if (re.test(all)) out.add(`${rel}: compiles in lyrebird's ${p}, which ${BUILD_SH} deletes as GPL`);
    }
  }
  return [...out];
}

/** Every regular file under [root], symlinks left out. */
function filesUnder(root) {
  const out = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const at = path.join(dir, e.name);
      if (e.isDirectory()) walk(at);
      else if (e.isFile()) out.push(at);
    }
  };
  walk(root);
  return out;
}

/** What [root] ships that LICENSE-001 or LICENSE-002 refuses, and what it read. */
function scan(root, { repo = REPO, goPaths = goGplPaths() } = {}) {
  const refusals = [];
  const files = filesUnder(root);
  let credits = 0;
  if (!files.some((f) => /(^|\/)flutter_assets\//.test(path.relative(root, f)))) {
    refusals.push(`${root}: no flutter_assets, so not an unpacked app`);
  }
  for (const file of files) {
    const rel = path.relative(root, file);
    if (isCredit(rel, file, repo)) {
      credits++;
      continue;
    }
    refusals.push(...findingsIn(fs.readFileSync(file), { rel, goPaths }));
  }
  return { refusals, files: files.length, credits };
}

module.exports = { goGplPaths, stringsOf, decoded, isCredit, findingsIn, scan, BUILD_SH };

if (require.main === module) {
  const root = process.argv[2];
  if (!root) {
    console.error('usage: node tool/check_artifact_licences.js <unpacked APK, IPA or .app>');
    process.exit(2);
  }
  const { refusals, files, credits } = scan(path.resolve(root));
  for (const line of refusals) console.error(`::error::${line}`);
  if (refusals.length) process.exit(1);
  console.log(`OK: ${files} files under ${root}, ${credits} of them the app's credits`);
}
