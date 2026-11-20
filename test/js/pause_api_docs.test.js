// PAUSE-003: the two pauses say which is which where a contributor reads them.
//
// `pause()` is per instance and saves resources; `pauseAllJsTimers()` is
// process-global on Android, so a call meant for one site freezes every
// site, the one about to show included. The interface is where a new call
// site is written, so the warnings live in its doc comments. Rung 5: no type
// says a method is process-global; this holds the doc comments that do.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const FILE = 'lib/services/webview_controller.dart';

/** The interface's body: from its declaration to its closing brace in column 0. */
function iface() {
  const src = read(FILE);
  const start = src.search(/^abstract (?:interface )?class WebViewController\b/m);
  assert.ok(start >= 0, `${FILE} declares no abstract WebViewController`);
  const end = src.indexOf('\n}', start);
  return src.slice(start, end);
}

/** The `///` lines directly above the abstract method [name] of the interface. */
function docOf(name) {
  const lines = iface().split('\n');
  const at = lines.findIndex((l) => new RegExp(`^\\s+Future<void> ${name}\\(\\);`).test(l));
  assert.ok(at >= 0, `WebViewController declares no abstract ${name}()`);
  const doc = [];
  for (let i = at - 1; i >= 0 && /^\s+\/\/\//.test(lines[i]); i--) doc.unshift(lines[i]);
  return doc.map((l) => l.replace(/^\s+\/\/\/ ?/, '')).join(' ').replace(/\s+/g, ' ');
}

test('PAUSE-003: pause and the JS timers are separate methods of the interface', () => {
  for (const name of ['pause', 'resume', 'pauseAllJsTimers', 'resumeAllJsTimers']) {
    assert.match(iface(), new RegExp(`^\\s+Future<void> ${name}\\(\\);`, 'm'), name);
  }
});

test('PAUSE-003: pause() says it is per instance and no security boundary', () => {
  const doc = docOf('pause');
  assert.match(doc.split('.')[0], /per-instance/i, 'the first sentence says what kind of pause it is');
  assert.match(doc, /not a security boundary/i);
});

test('PAUSE-003: pauseAllJsTimers() says it is process-global and not for one site', () => {
  const doc = docOf('pauseAllJsTimers');
  assert.match(doc.split('.')[0], /process-global/i, 'the first sentence says what kind of pause it is');
  assert.match(doc, /do \*\*not\*\* use it to pause a single site/i);
});
