// Archive container identity gate (ARCH-007, BUG-019).
//
// An archive-tier site binds `ws-<archiveContainerKey>`, never `ws-<siteId>`:
// the opaque id is what keeps the archived site's name off the disk. Every
// webview that runs as the site is told that key by the SitePosture it is built
// from, and every container operation takes a `ContainerKey`, which the compiler
// holds each surface to; what is left to check here is that the close sweeps
// any `ws-<siteId>` an earlier build bound without it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

test('the close sweeps ws-<siteId> for the archive, never an app-tier site', () => {
  const file = 'lib/controllers/archive_controller.dart';
  const close = blockAfter(read(file), 'final class CloseFlow {', null, file);
  const opaque = close.indexOf('for (final key in slice.containerKeys)');
  const sweep = close.indexOf('engine.onSiteDeleted(ContainerKey.ofSite(sid))');
  assert.notEqual(opaque, -1, 'the close must delete the opaque containers');
  assert.notEqual(sweep, -1, 'the close must delete ws-<siteId> for the archive sites');
  const guard = close.slice(opaque, sweep);
  assert.match(guard, /if \(!m\.isArchiveTier\) m\.siteId/,
    'the sweep must know which ids app-tier sites hold');
  assert.match(guard, /if \(!appTier\.contains\(sid\)\)/,
    'an id an app-tier site also holds names that site\'s own container');
});
