#!/usr/bin/env node
// The health line from CLAUDE.md's Coding principles, measured on the working
// tree and its history. Each number names the direction it should move.
//
//   node tool/architecture_health.js [--since=2026-04-01]
const { execFileSync } = require('node:child_process');
const { read, files, code } = require('../test/js/helpers/source');
const { upward } = require('../test/js/helpers/layers');

const since = (process.argv.find((a) => a.startsWith('--since=')) || '--since=6.months').slice(8);
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 28 });

const lib = files('lib', /\.dart$/).filter((f) => !f.startsWith('lib/l10n/'));
let lines = 0, comments = 0, asserts = 0, swallowed = 0, stringIds = 0, jsonPairs = 0;
for (const f of lib) {
  const raw = read(f);
  const rows = raw.split('\n');
  // Strings and comments blanked: a `catch (_)` in a JS shim string is not Dart.
  const src = code(raw, { strings: true });
  lines += rows.length;
  comments += rows.filter((l) => /^\s*(\/\/|\/\*|\*)/.test(l)).length;
  asserts += (src.match(/\bassert\(/g) || []).length;
  swallowed += (src.match(/catch\s*\(\s*_/g) || []).length;
  stringIds += (src.match(/\bString\??\s+\w*(?:Id|ID)\b/g) || []).length
    + (src.match(/(?:Set|List|Iterable)<String>\??\s+\w*Ids\b/g) || []).length;
  for (const cls of src.split(/\n(?=(?:abstract |final |sealed |base )*class )/)) {
    if (/^\s*(abstract |final |sealed |base )*class /.test(cls) && /\btoJson\s*\(/.test(cls) && /\bfromJson\b/.test(cls)) jsonPairs++;
  }
}

const gates = files('test/js', /\.test\.js$/);
const sourceGates = gates.filter((g) => /lib\/|dartFiles|methodBody|findMethod/.test(read(g)));

const FIX = /^(fix|keep|stop|don.t|guard|restore|recover|repair|prevent)\b/i;
const perFix = [];
let current = null;
for (const line of git('log', `--since=${since}`, '--format=@%s', '--name-only', '--', 'lib').split('\n')) {
  if (line.startsWith('@')) {
    if (current) perFix.push(current);
    current = FIX.test(line.slice(1)) ? 0 : null;
  } else if (line && current !== null) {
    current++;
  }
}
if (current !== null) perFix.push(current);
perFix.sort((a, b) => a - b);
const pct = (q) => (perFix.length ? perFix[Math.min(perFix.length - 1, Math.floor(q * perFix.length))] : 0);

const per1k = (n) => ((1000 * n) / lines).toFixed(2);
console.log([
  `files per fix commit since ${since}: median ${pct(0.5)}, p90 ${pct(0.9)} (${perFix.length} commits) ↓`,
  `gates ${gates.length} (${sourceGates.length} read source) ↓`,
  `catch (_) ${swallowed} ↓`,
  `asserts ${asserts}, ${per1k(asserts)} per 1k lines ↑`,
  `comment share ${((100 * comments) / lines).toFixed(1)}% ↓`,
  `String ids ${stringIds} → 0`,
  `hand-kept toJson/fromJson classes ${jsonPairs} → 0`,
  `layer violations ${upward().length} → 0`,
].join('\n'));
