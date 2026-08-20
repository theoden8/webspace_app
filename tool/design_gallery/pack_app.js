// Packs build/web into an uploadable copy of the designer app.
//
// The Claude Design project has no toolchain, so the built app is uploaded to
// it as plain files and iframed by the screen cards. Three differences from a
// plain build/web, all forced by living under a project subdirectory:
//
//   - <base href="/"> becomes "./", or every asset request escapes to the host
//     root and 404s;
//   - the service worker registration is dropped, since it would claim a scope
//     that is not ours and buys nothing for a design preview;
//   - *.symbols and .last_build_id are omitted (6MB of debug data).
//
//   node tool/design_gallery/pack_app.js [--src build/web] [--out build/design_app_upload]

const fs = require('node:fs');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

const SKIP = (rel) =>
  rel.endsWith('.symbols') ||
  path.basename(rel) === '.last_build_id' ||
  path.basename(rel) === 'flutter_service_worker.js';

function copyTree(src, out, rel = '') {
  const written = [];
  for (const entry of fs.readdirSync(path.join(src, rel), { withFileTypes: true })) {
    const childRel = path.join(rel, entry.name);
    if (entry.isDirectory()) {
      written.push(...copyTree(src, out, childRel));
      continue;
    }
    if (SKIP(childRel)) continue;
    fs.mkdirSync(path.join(out, rel), { recursive: true });
    fs.copyFileSync(path.join(src, childRel), path.join(out, childRel));
    written.push(childRel);
  }
  return written;
}

const src = path.resolve(arg('src', 'build/web'));
const out = path.resolve(arg('out', 'build/design_app_upload'));

if (!fs.existsSync(path.join(src, 'index.html'))) {
  console.error(`no build at ${path.relative(process.cwd(), src)}/index.html`);
  console.error('  run: scripts/design_web.sh app');
  process.exit(1);
}

fs.rmSync(out, { recursive: true, force: true });
const files = copyTree(src, out);

const indexPath = path.join(out, 'index.html');
const index = fs.readFileSync(indexPath, 'utf8');
if (!index.includes('<base href="/">')) {
  console.error('index.html has no <base href="/"> to rewrite; check the build');
  process.exit(1);
}
fs.writeFileSync(indexPath, index.replace('<base href="/">', '<base href="./">'));

const bootPath = path.join(out, 'flutter_bootstrap.js');
const boot = fs.readFileSync(bootPath, 'utf8');
const stripped = boot.replace(/\n?\s*serviceWorkerSettings:\s*\{[^}]*\},?/, '');
if (stripped === boot) {
  console.error('flutter_bootstrap.js has no serviceWorkerSettings block; check the build');
  process.exit(1);
}
fs.writeFileSync(bootPath, stripped);

const bytes = files.reduce((n, f) => n + fs.statSync(path.join(out, f)).size, 0);
console.log(`${files.length} files, ${(bytes / 1e6).toFixed(1)} MB -> ${path.relative(process.cwd(), out)}`);
