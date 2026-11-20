// DESIGN-009: a publish never clobbers a pending refresh request.
//
// The design project's `_requests/refresh.md` is a mailbox the design side
// writes; uploading the bundle over it would destroy a request nobody has
// read. So bundle.js ships the card pages, their manifest and README.md, and
// nothing from `project/_requests/`. This runs bundle.js on stub cards and
// reads what it wrote. The rest of the requirement is a protocol between two
// sessions (comparing a request's date with the serviced one), which no
// check here can run.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { REPO, read, files } = require('./helpers/source');

const BUNDLE = 'tool/design_gallery/bundle.js';

// A 1x1 PNG: bundle.js embeds each card as a data URI and never decodes it.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64');

/** Every file under the repo-relative [dir], relative to it. */
const tree = (dir) => files(dir, /./).map((f) => f.slice(dir.length + 1));

test('DESIGN-009: the bundle ships README.md and its pages, never the mailbox', () => {
  // Under the repo's build/, so its files are listed the way every gate
  // lists files (helpers/source.js).
  fs.mkdirSync(path.join(REPO, 'build'), { recursive: true });
  const work = fs.mkdtempSync(path.join(REPO, 'build', 'design-bundle-test-'));
  const workRel = path.relative(REPO, work);
  try {
    const cards = path.join(work, 'build', 'design_cards');
    fs.mkdirSync(cards, { recursive: true });
    for (const [, file] of read(BUNDLE).matchAll(/'([\w-]+\.png)'/g)) {
      fs.writeFileSync(path.join(cards, file), PNG);
    }
    execFileSync('node', [path.join(REPO, BUNDLE), '--out', 'out'], {
      cwd: work,
      env: { ...process.env, GIT_DIR: path.join(REPO, '.git') },
      stdio: 'pipe',
    });
    const out = path.join(work, 'out');
    const shipped = tree(`${workRel}/out`).sort();
    const manifest = JSON.parse(fs.readFileSync(path.join(out, '_ds_manifest.json'), 'utf8'));
    assert.deepEqual(shipped, [...manifest.cards.map((c) => c.path), 'README.md', '_ds_manifest.json'].sort(),
      'the bundle is the cards its manifest lists, the manifest and README.md: anything else is uploaded over the project');
    assert.ok(!shipped.some((f) => f.startsWith('_requests/') || f.endsWith('refresh.md')),
      'a publish that carries the mailbox destroys a pending request');
    assert.equal(fs.readFileSync(path.join(out, 'README.md'), 'utf8'),
      read('tool/design_gallery/project/README.md'));
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});
