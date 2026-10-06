// Archive container identity gate (ARCH-007, BUG-019).
//
// An archive-tier site binds `ws-<archiveContainerId>`, never `ws-<siteId>`:
// the opaque id is what keeps the archived site's name off the disk. Every
// webview that runs as the site is told that id by the SitePosture it is built
// from, which the compiler holds each surface to; what is left to check here is
// that the close sweeps any `ws-<siteId>` an earlier build bound without it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const root = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const main = read('lib/main.dart');

test('the close sweeps ws-<siteId> for the archive, never an app-tier site', () => {
  const close = blockAfter(main, '  Future<void> _closeArchive(ArchiveHandle handle) async {', null, 'lib/main.dart');
  const opaque = close.indexOf('for (final cid in slice.containerIds)');
  const sweep = close.indexOf('_containerIsolation.onSiteDeleted(sid)');
  assert.notEqual(opaque, -1, 'the close must delete the opaque containers');
  assert.notEqual(sweep, -1, 'the close must delete ws-<siteId> for the archive sites');
  const guard = close.slice(opaque, sweep);
  assert.match(guard, /if \(!m\.isArchiveTier\) m\.siteId/,
    'the sweep must know which ids app-tier sites hold');
  assert.match(guard, /if \(!appTier\.contains\(sid\)\)/,
    'an id an app-tier site also holds names that site\'s own container');
});
