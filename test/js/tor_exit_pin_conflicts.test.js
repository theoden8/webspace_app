// TOR-014: no path puts an exit pin in force while a site that disagrees
// with it is still loaded.
//
// tor has one ExitNodes, so the pin in force is the pin of every loaded Tor
// site. Activating a site unloads the siblings that disagree before the pin
// changes. Saving a site's settings did not: moving one site to Canada while
// a Denmark site was loaded changed the pin to {ca}, and the Denmark site was
// rebuilt under it as soon as Tor came back up, leaving from Canada.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/main.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

function body(signature) {
  const start = src.indexOf(signature);
  assert.notEqual(start, -1, `${rel} lost ${signature}`);
  const open = src.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(open, i + 1);
  }
  throw new Error(`unterminated ${signature}`);
}

function unloadsBeforePin(fn, label) {
  const pin = fn.indexOf('_syncTorExitPin(');
  assert.notEqual(pin, -1, `${label} no longer puts the pin in force`);
  const conflict = fn.search(/SiteUnloadEngine\.indicesToUnloadForTorExit\w*\(/);
  assert.notEqual(conflict, -1,
    `${label} changes the pin without asking which loaded sites disagree with it`);
  assert.ok(conflict < pin,
    `${label} computes the disagreeing sites only after the pin is in force`);
  const unload = fn.indexOf('_unloadSiteForOtherReason(', conflict);
  assert.ok(unload !== -1 && unload < pin,
    `${label} does not unload the disagreeing sites before the pin changes`);
}

test('activating a site unloads the siblings its pin disagrees with first', () => {
  unloadsBeforePin(body('Future<void> _setCurrentIndex('), '_setCurrentIndex');
});

test('saving settings unloads the sites the new pin disagrees with first', () => {
  unloadsBeforePin(body('Future<void> _syncTorHolders()'), '_syncTorHolders');
});
