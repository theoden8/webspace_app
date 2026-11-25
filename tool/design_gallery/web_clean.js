// Reports which UI files can appear in the design gallery (DESIGN-001).
//
// A widget is usable only if nothing in its transitive import closure reaches
// dart:io or dart:ffi, since neither compiles for web. Blocked files print the
// shortest chain to the offending leaf, which is the thing to break.
//
//   node tool/design_gallery/web_clean.js [dir ...]     # default: lib/main.dart lib/widgets lib/screens
//
// test/js/design_web_clean.test.js runs the same scan and counts it.

const fs = require('node:fs');
const path = require('node:path');

const BLOCKERS = new Set(['dart:io', 'dart:ffi']);
const DEFAULT_ROOTS = ['lib/main.dart', 'lib/widgets', 'lib/screens'];

// The directive's first uri is the one a web compile takes: every condition
// in lib/ is `dart.library.io`, false on web. An export is in the closure as
// an import is.
const DIRECTIVE = /^\s*(?:import|export)\s+['"]([^'"]+)['"]/gm;

function dartFilesUnder(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartFilesUnder(p));
    else if (entry.name.endsWith('.dart')) out.push(p);
  }
  return out;
}

// Every UI file under [roots] (a file or a directory, relative to [root])
// with the shortest chain to a blocker, or none.
function scan({ root = process.cwd(), roots = DEFAULT_ROOTS } = {}) {
  const rel = (p) => path.relative(root, p).split(path.sep).join('/');
  const imports = new Map();
  for (const file of dartFilesUnder(path.join(root, 'lib'))) {
    const src = fs.readFileSync(file, 'utf8');
    imports.set(rel(file), [...src.matchAll(DIRECTIVE)].map((m) => m[1]));
  }

  const resolve = (from, spec) => {
    if (spec.startsWith('package:webspace/')) return `lib/${spec.slice('package:webspace/'.length)}`;
    if (spec.startsWith('package:') || spec.startsWith('dart:')) return spec;
    return path.posix.normalize(path.posix.join(path.posix.dirname(from), spec));
  };

  const blockingChain = (start) => {
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
  };

  const files = roots
    .flatMap((r) => {
      const p = path.join(root, r);
      return fs.statSync(p).isDirectory() ? dartFilesUnder(p) : [p];
    })
    .map(rel)
    .sort();
  const clean = [];
  const blocked = [];
  for (const f of files) {
    const hit = blockingChain(f);
    hit ? blocked.push({ file: f, ...hit }) : clean.push(f);
  }
  return { files, clean, blocked };
}

module.exports = { scan, DEFAULT_ROOTS };

if (require.main === module) {
  const args = process.argv.slice(2);
  const dirs = args.filter((a) => !a.startsWith('--'));
  const { files, clean, blocked } = scan({ roots: dirs.length ? dirs : DEFAULT_ROOTS });

  // Zero blocked is the invariant, not an aspiration: the designer's environment
  // is the real app, and one `dart:io` in a widget takes the screens out of it.
  // A platform call belongs behind a conditional-export seam
  // (lib/platform/host_platform.dart, lib/services/file_store.dart, ...), whose
  // native half is unchanged. --report drops the exit code for exploration.
  const strict = !args.includes('--report');

  console.log(`web-clean (${clean.length}/${files.length}), usable in the gallery:`);
  for (const f of clean) console.log(`  ${f}`);
  console.log(`\nblocked (${blocked.length}):`);
  for (const { file, chain, leaf } of blocked) {
    console.log(`  ${file}`);
    console.log(`    ${chain.map((c) => c.replace(/^lib\//, '')).join(' -> ')} -> ${leaf}`);
  }

  if (strict && blocked.length) {
    console.error(`\n${blocked.length} UI file(s) no longer compile for web.`);
    console.error('  route the platform call through a seam, or the design gallery loses the screen');
    process.exitCode = 1;
  }
}
