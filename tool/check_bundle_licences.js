#!/usr/bin/env node
// LICENSE-001 over a built Linux package, which no build file names whole:
// every Debian copyright file it carries (a staged package's
// usr/share/doc/<package>/copyright, one linux/install_notices.sh wrote, the
// libraries tor's build copies beside it as lib/tor/docs/<package>.txt) names
// only licences openspec/specs/legal/licences.tsv lets ship as a shared
// library, read through debian_licences.tsv; and no file the package ships
// outside its notices carries a GNU licence's notice, but a debug source of a
// library whose copyright file names the LGPL, under the LGPL alone.
//
//   node tool/check_bundle_licences.js <unpacked package or bundle directory>

const fs = require('node:fs');
const path = require('node:path');
const L = require('../test/js/helpers/licences');
const { read } = require('../test/js/helpers/source');

const NAMES = 'openspec/specs/legal/debian_licences.tsv';

/** The rows of debian_licences.tsv: { name, spdx, pkg, files }. */
function names(text = read(NAMES)) {
  return L.rows(text).map(([name, spdx, pkg = '', files = '']) => ({
    name: name.trim(), spdx: spdx.trim(), pkg: pkg.trim(), files: files.trim().split(/\s+/).filter(Boolean),
  }));
}

/**
 * The SPDX id [name] stands for in a stanza of [pkg]'s file covering
 * [files]: that package's row whose files list every one of them (or that
 * names no files), else the generic row; null for a name no row reads.
 */
function spdxOf(name, { pkg, files, table }) {
  const own = table.find((r) => r.pkg === pkg && r.name === name
    && (r.files.length === 0 || files.every((f) => r.files.includes(f))));
  return (own ?? table.find((r) => !r.pkg && r.name === name))?.spdx ?? null;
}

/**
 * The licence expressions a DEP-5 copyright file's stanzas name, each in SPDX
 * ids, or the names no row reads. A stanza's commas group alternatives, so
 * each group is held on its own: "A or B, and C" is (A or B) and C.
 */
function licencesOf(text, { pkg, table = names() }) {
  if (!/^Format(-Specification)?:\s*\S/m.test(text)) return { expressions: [], unknown: ['(not a machine-readable copyright file)'] };
  const expressions = [];
  const unknown = [];
  for (const para of text.split(/\n[ \t]*\n/)) {
    const licence = para.match(/^License:[ \t]*(.+)$/m)?.[1];
    const filesField = para.match(/^Files:([^\n]*(?:\n[ \t][^\n]*)*)/m)?.[1];
    if (!licence || (!filesField && !/^Format/m.test(para))) continue;
    const files = filesField ? filesField.split(/\s+/).filter(Boolean) : ['*'];
    for (const group of licence.split(',')) {
      const words = group.trim().replace(/^(and|or)\s+/i, '').split(/\s+/).filter(Boolean);
      const spdx = words.map((w) => {
        if (/^(and|or)$/i.test(w)) return w.toUpperCase();
        const id = spdxOf(w, { pkg, files, table });
        if (!id) unknown.push(w);
        return id ?? w;
      });
      if (spdx.length) expressions.push(spdx.join(' '));
    }
  }
  return { expressions: [...new Set(expressions)], unknown: [...new Set(unknown)] };
}

/** Every copyright file under [root], with the package it is for. */
function copyrightFiles(root) {
  const out = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const at = path.join(dir, e.name);
      if (e.isDirectory()) walk(at);
      else if (e.name === 'copyright' && path.basename(path.dirname(path.dirname(at))) === 'doc') {
        out.push({ file: at, pkg: path.basename(path.dirname(at)) });
      } else if (/\.txt$/.test(e.name) && e.name !== 'tor.txt' && path.basename(dir) === 'docs'
        && path.basename(path.dirname(dir)) === 'tor') {
        out.push({ file: at, pkg: e.name.replace(/\.txt$/, '') });
      }
    }
  };
  walk(root);
  return out;
}

// flatpak-builder keeps a module's debug info and sources under
// lib/debug/source/<module>/, split into a .Debug extension the bundle leaves
// out; a source there under the LGPL is its library's, whose notices, in the
// flatpak's share/doc or a snap's usr/share/doc, must name the LGPL.
const DEBUG_SOURCE = /^lib\/debug\/source\/([^/]+)\//;
const copyrightsOf = (pkg) => [`share/doc/${pkg}/copyright`, `usr/share/doc/${pkg}/copyright`];

/** What [root] ships that LICENSE-001 refuses, one line each. */
function refusals(root, { table = names(), licences = L.policy() } = {}) {
  const out = [];
  const files = copyrightFiles(root);
  if (files.length === 0) out.push(`${root}: no copyright file at all`);
  const lgpl = new Set();
  for (const { file, pkg } of files) {
    const rel = path.relative(root, file);
    const { expressions, unknown } = licencesOf(fs.readFileSync(file, 'utf8'), { pkg, table });
    for (const name of unknown) out.push(`${rel}: ${name} is a name ${NAMES} does not read`);
    for (const e of expressions) {
      if (!unknown.length && !L.allows(e, { ships: 'shared', component: `deb:${pkg}`, licences })) {
        out.push(`${rel}: ${e}`);
      }
    }
    if (expressions.some((e) => /(^|[\s(])LGPL-/.test(e))) lgpl.add(rel);
  }
  const notices = new Set(files.map((f) => path.dirname(f.file)));
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const at = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (!notices.has(at) && !/(^|\/)(doc|docs|licenses|licences)$/.test(at)) walk(at);
      } else if (e.isFile() && L.readingOf(at, { licenceFile: false }).includes('a GNU licence')) {
        const rel = path.relative(root, at);
        const pkg = rel.match(DEBUG_SOURCE)?.[1];
        const lgplDebugSource = pkg && copyrightsOf(pkg).some((n) => lgpl.has(n)) && L.namesOnlyLgpl(at);
        if (!lgplDebugSource) out.push(`${rel}: carries a GNU licence's notice`);
      }
    }
  };
  walk(root);
  return out;
}

module.exports = { names, spdxOf, licencesOf, copyrightFiles, refusals, NAMES };

if (require.main === module) {
  const root = process.argv[2];
  if (!root) {
    console.error('usage: node tool/check_bundle_licences.js <package directory>');
    process.exit(2);
  }
  const found = refusals(path.resolve(root));
  for (const line of found) console.error(`::error::${line}`);
  if (found.length) process.exit(1);
  console.log(`OK: ${copyrightFiles(path.resolve(root)).length} copyright files under ${root}`);
}
