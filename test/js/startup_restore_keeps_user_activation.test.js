// Startup restore must not close a site the user already opened (NAV-012).
//
// `StartupController.restore` puts the home grid on screen early and then keeps
// awaiting startup work: the proxy router's attribution pass, container GC,
// shortcut resolution. A tap on the grid in that window runs
// `activate(site)`, and the restore's closing activation used to run
// `activate(target)` regardless. On a plain launch that target
// is null, so the site the user had just opened was quiesced and the app went
// back home. The decision lives in `StartupRestoreEngine
// .shouldActivateAfterRestore`; this gate keeps the restore asking it, with the
// activation version captured before the first await.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const rel = 'lib/controllers/startup_controller.dart';
const src = read(rel);
const restore = blockAfter(src, 'Future<void> restore() async {', null, rel);

test('the activation version is captured before the restore first awaits', () => {
  const capture = restore.indexOf(
    'final activationVersionAtRestore = _sites.activationVersion;');
  assert.notEqual(capture, -1,
    'restore must record _sites.activationVersion on entry');
  const firstAwait = restore.indexOf('await ');
  assert.ok(firstAwait === -1 || capture < firstAwait,
    'a tap landing before the capture would be read as the restore\'s own state');
});

test('every restore activation asks the engine first', () => {
  const activate = blockAfter(src, 'Future<Reached<Launched>?> _activate(', null, rel);
  const calls = [...activate.matchAll(/await _activation\.activate\(([^)]*)\);/g)];
  assert.ok(calls.length >= 1, 'the restore no longer activates a site');
  for (const call of calls) {
    const before = activate.slice(Math.max(0, call.index - 400), call.index);
    assert.match(before,
      /if \(StartupRestoreEngine\.shouldActivateAfterRestore\(\s*opensSite: launchAt != null,\s*activatedDuringRestore:\s*_sites\.activationVersion != activationVersionAtRestore,\s*\)\) \{\s*$/,
      `activate(${call[1]}) in restore must be guarded by ` +
      'StartupRestoreEngine.shouldActivateAfterRestore, or a site opened during ' +
      'startup is closed again');
  }
  assert.match(restore, /activationVersionAtRestore: activationVersionAtRestore/,
    'the version the restore captured on entry must reach the activation');
});

// ISO-012: the launch jar clear once ran in the post-paint sweep, outside the
// jar's turns, after the launched site's restore had refilled the jar, and
// signed the loaded sites out. It is queued now before the commit that makes
// the grid tappable, so it is the jar's first turn. The commit takes the
// isolation the step bound, so the order of the two steps is a type; rung 5
// for what is left, that the step queues the clear in the same turn it binds
// the jar, before it hands the isolation out.
// formal/activation.tla's lateclear is the design half.
test('the launch jar clear is queued before the sites are committed', () => {
  const bind = blockAfter(src, 'Future<Isolation> _bindIsolation() async {', null, rel);
  const clear = bind.indexOf('jar.clearUnloaded(');
  const proof = bind.indexOf('return isolation;');
  assert.notEqual(clear, -1, 'the isolation step must queue the shared jar\'s clear');
  assert.ok(clear < proof, 'the clear must be queued before the isolation leaves the step');
  assert.doesNotMatch(bind.slice(bind.indexOf('_sites.isolation ='), clear), /await /,
    'nothing may run between binding the jar and queueing its clear');
  assert.match(src, /_putSitesOnPage\(\{[^}]*required Isolation isolation,/s,
    'the commit must take the bound isolation');
  assert.doesNotMatch(read('lib/controllers/page_orphan_sweep.dart'), /deleteAllCookies/,
    'the post-paint sweep must not empty the jar');
});
