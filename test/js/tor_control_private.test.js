// The Tor control channel stays inside the app (LEAK-014).
//
// tor authenticates every control connection with its cookie, and the cookie
// never leaves the Swift plugin, so no backup, log or page can carry it:
// Dart never holds it. Rung 5: what a Swift value carries across a method
// channel is no Dart type. The channel's own kind (a Unix socket in a 0700
// directory, else tor's loopback auto port) is pinned by
// tor_suspension.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code, blockAfter, dartFiles, lineAt } = require('./helpers/source');

const raw = read('ios/Runner/TorControllerPlugin.swift');

test('tor authenticates its control channel with the cookie (LEAK-014)', () => {
  const launch = blockAfter(code(raw), 'func launchLocked(');
  assert.match(launch, /config\.cookieAuthentication = true/);
});

test('the control cookie is read only to authenticate (LEAK-014)', () => {
  const swift = code(raw, { strings: true });
  const uses = [...swift.matchAll(/\bcookie\b/g)];
  assert.ok(uses.length > 0, 'the plugin reads the cookie somewhere');
  for (const m of uses) {
    const line = swift
      .slice(swift.lastIndexOf('\n', m.index) + 1, swift.indexOf('\n', m.index))
      .trim();
    assert.match(line, /^(guard )?let cookie = config\.cookie\b|\.authenticate\(with: cookie\)/,
      `TorControllerPlugin.swift:${lineAt(raw, m.index)} hands the cookie to more than authenticate: ${line}`);
  }
});

test('no app code reaches the control channel (LEAK-014)', () => {
  // tor's status names its control socket for an integration test's own
  // connection; nothing under lib/ may read it.
  for (const f of dartFiles()) {
    assert.doesNotMatch(code(read(f)), /['"]controlSocket['"]/,
      `${f} reads the control socket's path`);
  }
});
