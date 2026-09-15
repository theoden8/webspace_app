// Tor bootstrap observability gate (TOR-018).
//
// Three things have to agree across the platform seam for a user to see
// what tor is doing: the plugin has to forward the phase tor reports, Dart
// has to decode it under the same keys, and both sides have to name the log
// channel identically. A rename on one side alone is silent — the UI simply
// shows a percentage with no phase again, which is the report this came
// from. There is no iOS toolchain in this repo's CI tiers, so the guard is
// structural, like native_bgtask_completion_funnel.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const swiftRel = 'ios/Runner/TorControllerPlugin.swift';
const dartRel = 'lib/services/tor_service.dart';
const swift = fs.readFileSync(path.join(repoRoot, swiftRel), 'utf8');
const dart = fs.readFileSync(path.join(repoRoot, dartRel), 'utf8');

/// Code only. The comments below name the very calls this file forbids, so
/// a scan over the raw source would fail on the explanation of the rule.
const swiftCode = swift.replace(/^\s*\/\/.*$/gm, '');

/// The body of a `func <name>` in Swift source, brace-matched. Used to say
/// "this call may only appear here", which is the shape of two rules below.
function functionBody(src, name) {
  const at = src.indexOf(`func ${name}(`);
  assert.ok(at >= 0, `${swiftRel} must declare ${name}`);
  let open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(open, i + 1);
  }
  throw new Error(`unbalanced braces in ${name}`);
}

test('the plugin forwards tor\'s bootstrap phase, not just the percentage', () => {
  assert.match(swift, /arguments\?\["TAG"\]/,
    `${swiftRel} must read TAG off the BOOTSTRAP status event`);
  assert.match(swift, /arguments\?\["SUMMARY"\]/,
    `${swiftRel} must read SUMMARY off the BOOTSTRAP status event`);
  for (const key of ['bootstrapTag', 'bootstrapSummary']) {
    assert.ok(swift.includes(`payload["${key}"]`),
      `${swiftRel} must publish ${key} in the status payload`);
  }
});

test('Dart decodes the phase under the keys the plugin publishes', () => {
  for (const key of ['bootstrapTag', 'bootstrapSummary']) {
    assert.ok(dart.includes(`raw['${key}']`),
      `${dartRel} must decode ${key}; the widgets render the phase from it`);
  }
});

test('both sides name the log channel identically', () => {
  const name = 'org.codeberg.theoden8.webspace/tor/logs';
  assert.ok(swift.includes(`"${name}"`), `${swiftRel} must serve ${name}`);
  assert.ok(dart.includes(`'${name}'`), `${dartRel} must subscribe to ${name}`);
});

test('the plugin subscribes to tor\'s own log severities', () => {
  const events = swift.match(/kTorControlEvents = \[([^\]]*)\]/);
  assert.ok(events, `${swiftRel} must declare the control-port event list`);
  for (const event of ['STATUS_CLIENT', 'NOTICE', 'WARN', 'ERR']) {
    assert.ok(events[1].includes(`"${event}"`),
      `${swiftRel} must subscribe to ${event}`);
  }
  // INFO and DEBUG name every connection tor makes: high volume, and
  // per-destination detail that has no business in an in-app log ring.
  for (const event of ['INFO', 'DEBUG']) {
    assert.ok(!events[1].includes(`"${event}"`),
      `${swiftRel} must not subscribe to ${event}`);
  }
});

test('nothing re-sends SETEVENTS behind the log subscription', () => {
  // `addObserver(forCircuitEstablished:)` and `listenForEvents` both send
  // SETEVENTS with their own list, which drops NOTICE/WARN/ERR and leaves
  // the log silently dead. CIRCUIT_ESTABLISHED is handled in the status
  // observer instead.
  for (const bad of [/forCircuitEstablished:/, /\.listenForEvents\(/]) {
    assert.ok(!bad.test(swiftCode),
      `${swiftRel} re-subscribes events (${bad}), unsubscribing tor's log`);
  }
  assert.match(swift, /case "CIRCUIT_ESTABLISHED":/,
    `${swiftRel} must handle CIRCUIT_ESTABLISHED in the status observer`);
});

test('tor\'s log still never lands on disk', () => {
  // The control port is the log surface precisely so nothing is written to
  // the app container, where it would outlive the session and name the
  // bridges this device dials (TOR-017).
  assert.match(swift, /"Log": "err file \/dev\/null"/,
    `${swiftRel} must keep tor's file log pointed at /dev/null`);
  assert.ok(!/\.logfile\s*=/.test(swiftCode),
    `${swiftRel} must not set TorConfiguration.logfile`);
});

test('tor\'s own output is filed as sensitive', () => {
  // A notice-level line can name a bridge. Sensitive entries stay in the
  // memory-only ring and are shown only behind the Dev Tools toggle.
  assert.match(dart, /fromTor \? LogSensitivity\.sensitive : LogSensitivity\.normal/,
    `${dartRel} must file tor's own lines as sensitive`);
});

test('one tor per process, and a start waits for the last one to leave', () => {
  // TORThread asserts a single instance per process, and two tor_run_main
  // calls in one address space fight over the data-directory lock — which
  // tor settles by exiting the process it is linked into. BUG-007 attempt 6.
  const constructions = (swiftCode.match(/TorThread\(/g) || []).length;
  assert.equal(constructions, 1,
    `${swiftRel} must construct exactly one TorThread, found ${constructions}`);
  assert.ok(functionBody(swiftCode, 'launchLocked').includes('TorThread('),
    'the one construction belongs in launchLocked, behind the exit wait');

  const wait = functionBody(swiftCode, 'launchWhenFreeLocked');
  assert.match(wait, /exitingThread[\s\S]*isFinished/,
    'the start path must wait on the previous thread finishing');
  assert.match(functionBody(swiftCode, 'start'), /launchWhenFreeLocked\(/,
    'start must go through the exit wait, not straight to a launch');

  const stop = functionBody(swiftCode, 'stop');
  assert.match(stop, /exitingThread = thread/,
    'stop must hand the running thread to the exit watch');
  assert.ok(!/thread\?\.cancel\(\)/.test(stop),
    'NSThread.cancel() does not stop tor; SIGNAL SHUTDOWN over the control port does');
  assert.match(stop, /disconnect\(\)/,
    'stop must disconnect the controller, which is what asks tor to exit');
});

test('an earlier run cannot speak for the current one', () => {
  // Generation guards: a handshake, catch-up read or failure from a run
  // that was already stopped must not resurrect or overwrite the live one.
  for (const name of ['attachController', 'observeLocked', 'launchWhenFreeLocked']) {
    assert.match(functionBody(swiftCode, name), /generation == self\.generation|generation, generation == self\.generation/,
      `${name} must check the run generation before touching shared state`);
  }
  assert.match(swiftCode, /self\.generation \+= 1/,
    'start and stop must bump the generation');
});

test('every control-port read happens before events are subscribed', () => {
  // Tor.framework routes replies and asynchronous events through one
  // observer list, and its GETINFO observer answers the first line it is
  // handed — an unrelated event included, which it reports as an empty
  // result. A read taken once NOTICE/BOOTSTRAP events are flowing is the
  // bug that made a finished bootstrap report "no usable SOCKS listener".
  const reads = (swiftCode.match(/info\(forKeys:/g) || []).length;
  const inObserve = (functionBody(swiftCode, 'observeLocked').match(/info\(forKeys:/g) || []).length;
  assert.equal(reads, inObserve,
    `${swiftRel} reads the control port outside observeLocked's quiet window`);
  assert.ok(reads > 0, 'observeLocked must still read the phase and the SOCKS listener');

  const observe = functionBody(swiftCode, 'observeLocked');
  assert.ok(observe.lastIndexOf('info(forKeys:') < observe.indexOf('subscribeLocked('),
    'the reads must come before the SETEVENTS subscription, not after');
});

test('macOS carries the same pinned runtime as iOS', () => {
  // The macOS runtime is what integration_test/tor_test.dart drives, so a
  // version skew between the two platforms would mean testing something
  // other than what iOS ships. Same pods, same pins, one floor.
  const iosPods = fs.readFileSync(path.join(repoRoot, 'ios/Podfile'), 'utf8');
  const macPods = fs.readFileSync(path.join(repoRoot, 'macos/Podfile'), 'utf8');
  for (const pod of ['Tor', 'IPtProxy']) {
    const pin = new RegExp(`pod '${pod}', '([0-9.]+)'`);
    const ios = iosPods.match(pin);
    const mac = macPods.match(pin);
    assert.ok(ios, `ios/Podfile must pin ${pod}`);
    assert.ok(mac, `macos/Podfile must pin ${pod}`);
    assert.equal(mac[1], ios[1],
      `${pod} is pinned to ${mac[1]} on macOS and ${ios[1]} on iOS`);
  }

  // The Tor pod is a macOS 11 pod; anything lower does not install, and a
  // project floor below the Podfile's links a module built for a newer OS
  // than the target it lands in.
  assert.match(macPods, /platform :osx, '11\.0'/,
    'macos/Podfile must declare the floor the Tor pod needs');
  const macPbx = fs.readFileSync(
    path.join(repoRoot, 'macos/Runner.xcodeproj/project.pbxproj'), 'utf8');
  assert.ok(!/MACOSX_DEPLOYMENT_TARGET = 10\.15/.test(macPbx),
    'a target still sits below the Podfile floor');

  // Availability is capability; developer mode is permission, and it lives
  // on TorService. Conflating them is what TOR-007 says not to do.
  assert.match(dart, /defaultTargetPlatform == TargetPlatform\.macOS/,
    `${dartRel} must report the macOS runtime as available`);
});

test('one plugin source, built by both Apple targets', () => {
  // The macOS runtime is only worth testing because it is the same code as
  // the iOS one. A copy would drift, and the bugs this file guards lived in
  // exactly the part that would drift.
  const refs = {
    // iOS keeps the plain in-group reference it has always had: it is the
    // shipping target, so the reference that crosses a directory boundary
    // is the macOS one, never this.
    'ios/Runner.xcodeproj': /path = TorControllerPlugin\.swift; sourceTree = "<group>"/,
    'macos/Runner.xcodeproj': /path = \.\.\/ios\/Runner\/TorControllerPlugin\.swift/,
  };
  for (const [project, expected] of Object.entries(refs)) {
    const pbx = fs.readFileSync(
      path.join(repoRoot, project, 'project.pbxproj'), 'utf8');
    assert.match(pbx, expected, `${project} must reference the one source`);
    // Twice: the PBXBuildFile that defines it, and the Sources phase that
    // lists it. Matching once would pass on a file that is defined and then
    // never compiled.
    const compiled =
      (pbx.match(/TorControllerPlugin\.swift in Sources/g) || []).length;
    assert.ok(compiled >= 2,
      `${project} references the shared source but does not compile it`);
  }
  for (const copy of ['darwin/TorControllerPlugin.swift',
                      'macos/Runner/TorControllerPlugin.swift']) {
    assert.ok(!fs.existsSync(path.join(repoRoot, copy)),
      `${copy} is a second copy of the plugin, which will drift`);
  }
  assert.match(swift, /#if canImport\(FlutterMacOS\)/,
    'the shared source must pick its Flutter module per platform');
});
