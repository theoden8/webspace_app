#!/usr/bin/env node
// LICENSE-001 over the Maven artifacts the Android build links, transitive
// ones included, which android/app/maven_licences.gradle lists with the
// licences their POMs name: each read through maven_licences.tsv and held to
// licences.tsv as linked into the app. Run by CI after the build.
//
//   node tool/check_maven_licences.js assets/native_notices/maven.json

const fs = require('node:fs');
const L = require('../test/js/helpers/licences');
const { read } = require('../test/js/helpers/source');

const PATTERNS = 'openspec/specs/legal/maven_licences.tsv';

/** The rows of maven_licences.tsv: patterns and artifacts read by hand. */
function table(text = read(PATTERNS)) {
  const patterns = [];
  const byHand = new Map();
  for (const [pattern, spdx] of L.rows(text)) {
    if (pattern.startsWith('gradle:')) byHand.set(pattern.trim(), spdx.trim());
    else patterns.push([new RegExp(pattern.trim(), 'i'), spdx.trim()]);
  }
  return { patterns, byHand };
}

/** The SPDX id a POM licence stands for, or null. */
function spdxOf({ name, url }, { patterns }) {
  const text = `${name} ${url}`;
  return patterns.find(([re]) => re.test(text))?.[1] ?? null;
}

/** Each artifact of [entries] LICENSE-001 refuses, one line each. */
function refusals(entries, { rows = table(), licences = L.policy() } = {}) {
  const out = [];
  for (const { group, artifact, version, licences: named = [] } of entries) {
    const component = `gradle:${group}:${artifact}`;
    const label = `${group}:${artifact}:${version}`;
    let expression = rows.byHand.get(component) ?? null;
    if (expression === null) {
      if (named.length === 0) {
        out.push(`${label}: its POM names no licence; read it by hand into ${PATTERNS}`);
        continue;
      }
      const ids = named.map((l) => spdxOf(l, rows));
      const unknown = named.filter((_, i) => ids[i] === null).map((l) => l.name || l.url);
      if (unknown.length) {
        out.push(`${label}: ${unknown.join(', ')} is a licence ${PATTERNS} does not read`);
        continue;
      }
      expression = [...new Set(ids)].join(' AND ');
    }
    if (!L.allows(expression, { ships: 'linked', component, licences })) out.push(`${label}: ${expression}`);
  }
  return out;
}

module.exports = { table, spdxOf, refusals, PATTERNS };

if (require.main === module) {
  const file = process.argv[2];
  if (!file) {
    console.error('usage: node tool/check_maven_licences.js <maven.json>');
    process.exit(2);
  }
  const entries = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(entries) || entries.length === 0) {
    console.error(`::error::${file} lists no artifact`);
    process.exit(1);
  }
  const found = refusals(entries);
  for (const line of found) console.error(`::error::${line}`);
  if (found.length) process.exit(1);
  console.log(`OK: ${entries.length} Maven artifacts`);
}
