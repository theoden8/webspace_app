// Reports which UI files can appear in the design gallery.
//
// A widget is usable only if nothing in its transitive import closure reaches
// dart:io or dart:ffi, since neither compiles for web. Blocked files print the
// shortest chain to the offending leaf, which is the thing to break.
//
//   node tool/design_gallery/web_clean.js [dir ...]     # default: lib/widgets lib/screens

const fs = require('node:fs');
const path = require('node:path');

const BLOCKERS = new Set(['dart:io', 'dart:ffi']);
const roots = process.argv.slice(2).length ? process.argv.slice(2) : ['lib/widgets', 'lib/screens'];

const imports = new Map();
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p);
    else if (entry.name.endsWith('.dart')) {
      const src = fs.readFileSync(p, 'utf8');
      imports.set(p, [...src.matchAll(/import\s+['"]([^'"]+)['"]/g)].map((m) => m[1]));
    }
  }
})('lib');

const resolve = (from, spec) => {
  if (spec.startsWith('package:webspace/')) return path.join('lib', spec.slice('package:webspace/'.length));
  if (spec.startsWith('package:') || spec.startsWith('dart:')) return spec;
  return path.normalize(path.join(path.dirname(from), spec));
};

// Shortest import chain from `start` to any dart:io / dart:ffi importer.
function blockingChain(start) {
  const queue = [[start]];
  const seen = new Set([start]);
  while (queue.length) {
    const chain = queue.shift();
    const file = chain[chain.length - 1];
    for (const spec of imports.get(file) || []) {
      const target = resolve(file, spec);
      if (BLOCKERS.has(target)) return { chain, leaf: target };
      if (target.startsWith('dart:') || target.startsWith('package:') || seen.has(target)) continue;
      seen.add(target);
      queue.push([...chain, target]);
    }
  }
  return null;
}

const files = roots.flatMap((r) => fs.readdirSync(r).filter((f) => f.endsWith('.dart')).map((f) => path.join(r, f))).sort();
const clean = [];
const blocked = [];
for (const f of files) {
  const hit = blockingChain(f);
  hit ? blocked.push([f, hit]) : clean.push(f);
}

console.log(`web-clean (${clean.length}/${files.length}), usable in the gallery:`);
for (const f of clean) console.log(`  ${f}`);
console.log(`\nblocked (${blocked.length}):`);
for (const [f, { chain, leaf }] of blocked) {
  console.log(`  ${f}`);
  console.log(`    ${chain.map((c) => c.replace(/^lib\//, '')).join(' -> ')} -> ${leaf}`);
}
