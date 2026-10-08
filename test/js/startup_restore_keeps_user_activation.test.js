// Startup restore must not close a site the user already opened (NAV-012).
//
// `_restoreAppState` puts the home grid on screen early and then keeps
// awaiting startup work: the proxy router's attribution pass, container GC,
// shortcut resolution. A tap on the grid in that window runs
// `_setCurrentIndex(i)`, and the restore's closing activation used to run
// `_setCurrentIndex(indexToRestore)` regardless. On a plain launch that target
// is null, so the site the user had just opened was quiesced and the app went
// back home. The decision lives in `StartupRestoreEngine
// .shouldActivateAfterRestore`; this gate keeps the restore asking it, with the
// activation version captured before the first await.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const rel = 'lib/screens/webspace_page.dart';
const src = read(rel);
const restore = blockAfter(src, 'Future<void> _restoreAppState() async {', null, rel);

test('the activation version is captured before the restore first awaits', () => {
  const capture = restore.indexOf(
    'final activationVersionAtRestore = _sites.activationVersion;');
  assert.notEqual(capture, -1,
    '_restoreAppState must record _sites.activationVersion on entry');
  const firstAwait = restore.indexOf('await ');
  assert.ok(firstAwait === -1 || capture < firstAwait,
    'a tap landing before the capture would be read as the restore\'s own state');
});

test('every restore activation asks the engine first', () => {
  const calls = [...restore.matchAll(/await _setCurrentIndex\(([^)]*)\);/g)];
  assert.ok(calls.length >= 1, '_restoreAppState no longer activates a site');
  for (const call of calls) {
    const before = restore.slice(Math.max(0, call.index - 400), call.index);
    assert.match(before,
      /if \(StartupRestoreEngine\.shouldActivateAfterRestore\(\s*indexToRestore: indexToRestore,\s*activatedDuringRestore:\s*_sites\.activationVersion != activationVersionAtRestore,\s*\)\) \{\s*$/,
      `_setCurrentIndex(${call[1]}) in _restoreAppState must be guarded by ` +
      'StartupRestoreEngine.shouldActivateAfterRestore, or a site opened during ' +
      'startup is closed again');
  }
});
