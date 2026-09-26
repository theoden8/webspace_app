// Archive container identity gate (ARCH-007, BUG-019).
//
// An archive-tier site binds `ws-<archiveContainerId>`, never `ws-<siteId>`:
// the opaque id is what keeps the archived site's name off the disk. Every
// webview that runs as the site has to be told that id, including the nested
// screen, and the close sweeps any `ws-<siteId>` a path bound without it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const root = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const main = read('lib/main.dart');
const nested = read('lib/screens/inappbrowser.dart');

function callText(text, from) {
  const open = text.indexOf('(', from);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '(') depth++;
    else if (text[i] === ')' && --depth === 0) return text.slice(open + 1, i);
  }
  assert.fail(`unbalanced parentheses at offset ${from}`);
}

test('the nested webview binds by the opaque id', () => {
  const config = callText(nested, nested.indexOf('config: WebViewConfig('));
  assert.match(config, /archiveContainerId: widget\.archiveContainerId,/);
});

test('an existing site opens nested with its own opaque id', () => {
  const at = main.indexOf('_launchNestedForModel(WebViewModel model, String url) =>');
  const funnel = callText(main, main.indexOf('launchUrl(', at));
  assert.match(funnel, /archiveContainerId: model\.archiveContainerId,/);
});

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
