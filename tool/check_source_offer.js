#!/usr/bin/env node
// LICENSE-004 over a built Linux package: the source each bundled LGPL
// library's copyright file offers (linux/install_notices.sh --offer) can be
// given for as long as the offer runs. The file names the commit it was built
// from, and Software Heritage, which keeps what it archives, must hold that
// commit and its tree, so the copy outlives the upstream repository.
//
//   node tool/check_source_offer.js <unpacked or installed package>

const fs = require('node:fs');
const path = require('node:path');

const ARCHIVE = 'https://archive.softwareheritage.org/api/1';
const OFFER = 'For at least three years from the day you received this copy';

// Where a package keeps its libraries' notices, as bundledDocsDir() in
// lib/services/bundled_notices_io.dart reads them: a snap's /usr/share/doc,
// a flatpak's /app/share/doc.
const DOC_DIRS = ['usr/share/doc', 'share/doc'];

/** Each copyright file under [root] that makes the offer: { file, source, revision }. */
function offers(root) {
  const out = [];
  for (const dir of DOC_DIRS) out.push(...offersIn(root, path.join(root, dir)));
  return out;
}

function offersIn(root, doc) {
  if (!fs.existsSync(doc)) return [];
  const out = [];
  for (const name of fs.readdirSync(doc).sort()) {
    const file = path.join(doc, name, 'copyright');
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, 'utf8');
    if (!text.includes(OFFER)) continue;
    const built = text.match(/^Comment: Built (?:as it is )?from (\S+) at ([^\s,]+?)(?:\.$|, )/m);
    out.push({ file: path.relative(root, file), source: built?.[1] ?? null, revision: built?.[2] ?? null });
  }
  return out;
}

/** Why [offer] could not be given, one line each, asking the archive through [getJson]. */
async function refusals(offer, { getJson }) {
  const at = `${offer.file}: `;
  if (!/^[0-9a-f]{40}$/.test(offer.revision ?? '')) {
    return [`${at}offers ${offer.source} at ${offer.revision}, not a commit an archive keeps`];
  }
  const revision = await getJson(`${ARCHIVE}/revision/${offer.revision}/`);
  if (typeof revision?.directory !== 'string') {
    return [`${at}Software Heritage does not hold ${offer.revision}; ask it to archive ${offer.source}`
      + ' (https://archive.softwareheritage.org/save/) and run this again once it does'];
  }
  const tree = await getJson(`${ARCHIVE}/directory/${revision.directory}/`);
  if (!Array.isArray(tree) || tree.length === 0) {
    return [`${at}Software Heritage holds ${offer.revision} but not its tree ${revision.directory}`];
  }
  return [];
}

/** The archive's answer to [url]: its JSON, or null where it holds nothing there. */
async function archiveJson(url) {
  const reply = await fetch(url, { headers: { accept: 'application/json' } });
  if (reply.status === 404) return null;
  if (!reply.ok) throw new Error(`${url}: HTTP ${reply.status}`);
  return reply.json();
}

module.exports = { offers, refusals, OFFER };

if (require.main === module) {
  const root = process.argv[2];
  if (!root) {
    console.error('usage: node tool/check_source_offer.js <package directory>');
    process.exit(2);
  }
  (async () => {
    const found = offers(path.resolve(root));
    const lines = found.length ? [] : [`${root}: no copyright file makes the source offer`];
    for (const offer of found) lines.push(...await refusals(offer, { getJson: archiveJson }));
    for (const line of lines) console.error(`::error::${line}`);
    if (lines.length) process.exit(1);
    for (const o of found) console.log(`OK: ${o.file} offers ${o.source} at ${o.revision}, held by Software Heritage`);
  })();
}
