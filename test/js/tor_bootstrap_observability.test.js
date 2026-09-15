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

test('tor\'s own log reaches the app, from a file it can always read', () => {
  // It used to come over the control port. A tor that never opens one is
  // exactly the tor whose log matters, and on a device where that happened
  // every surface in the app was blind (BUG-013). tor writes to a file in
  // the run's data directory now and the plugin tails it.
  assert.match(swiftCode, /config\.logfile = logFile/,
    `${swiftRel} must give tor a log file`);
  assert.match(swiftCode, /removeItem\(at: logFile\)/,
    'the file must be truncated at start, so a run never reads the last one');
  const stopBody = functionBody(swiftCode, 'stop');
  assert.match(stopBody, /removeItem\(at: url\)/,
    'the file must not outlive the run that wrote it');
  assert.match(stopBody, /pumpLogLocked\(\)/,
    'the last thing tor wrote on its way out must be forwarded first');
  assert.match(functionBody(swiftCode, 'pumpLogLocked'), /logRelay\.emit\(source: "tor"/,
    'the tail must reach the app log');
  assert.ok(!/"Log": "err file/.test(swiftCode),
    'the /dev/null log target is gone; the file replaced it');
});

test('the event subscription stays as narrow as it needs to be', () => {
  const events = swiftCode.match(/kTorControlEvents = \[([^\]]*)\]/);
  assert.ok(events, `${swiftRel} must declare the control-port event list`);
  assert.ok(events[1].includes('"STATUS_CLIENT"'),
    'STATUS_CLIENT drives the state machine');
  // The log severities are no longer subscribed: they would duplicate the
  // file tail. INFO and DEBUG never were and must not be, since they name
  // every connection tor makes.
  for (const event of ['NOTICE', 'WARN', 'ERR', 'INFO', 'DEBUG']) {
    assert.ok(!events[1].includes(`"${event}"`),
      `${swiftRel} must not subscribe to ${event}`);
  }
  assert.ok(!/forCircuitEstablished:/.test(swiftCode),
    'that observer sends its own SETEVENTS and follows it with a GETINFO an '
      + 'event can answer, after which it removes itself (TOR-019)');
  assert.match(swiftCode, /case "CIRCUIT_ESTABLISHED":/,
    `${swiftRel} must handle CIRCUIT_ESTABLISHED in the status observer`);
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
  assert.match(functionBody(swiftCode, 'retireRunningLocked'), /exitingThread = thread/,
    'a retired run must hand its thread to the exit watch');
  assert.ok(!/thread\?\.cancel\(\)/.test(stop),
    'NSThread.cancel() does not stop tor; SIGNAL SHUTDOWN over the control port does');
  assert.match(stop, /disconnect\(\)/,
    'stop must disconnect the controller, which is what asks tor to exit');
});

test('the control port gets a budget a phone can meet', () => {
  // Three attempts inside 1.5s failed runs that would have been fine a
  // second later, and left a tor behind that nothing could talk to. The
  // budget is now a poll interval times a count, and the exit wait has to
  // outlast the shutdown loop or it gives up mid-request.
  const value = (name) => {
    const m = swiftCode.match(new RegExp(`let ${name} = ([0-9.]+)`));
    assert.ok(m, `${swiftRel} must declare ${name}`);
    return Number(m[1]);
  };
  const attach = value('kTorAttachPoll') * value('kTorAttachAttempts');
  assert.ok(attach >= 20,
    `the control-port budget is ${attach}s; a cold start on a busy phone needs more`);
  const halt = value('kTorHaltRetryDelay') * value('kTorHaltRetries');
  const exit = value('kTorThreadExitPoll') * value('kTorThreadExitAttempts');
  assert.ok(exit >= halt,
    `the exit wait (${exit}s) gives up before the shutdown loop (${halt}s) is done`);
  assert.match(functionBody(swiftCode, 'attachLocked'), /attempt < kTorAttachAttempts/,
    'the attach loop must be bounded by that count');
});

test('a stop can reach a tor it never adopted a controller for', () => {
  // The stop path used to be `controller?.disconnect()`, which is a no-op
  // when no controller was ever adopted -- a runtime stopped before its
  // handshake landed, or one whose handshake failed. That tor then ran
  // until the app was killed and every later start refused, because only
  // one tor may run per process (TOR-020). BUG-007 attempt 7.
  const halt = functionBody(swiftCode, 'halt');
  assert.match(halt, /connectedController\(to: portFile\)/,
    'the halt path must open its own control connection, not reuse one');
  assert.match(halt, /authenticate\(with: cookie\)/,
    'it must authenticate with the configuration cookie');
  // Every way this can fail has to name itself: an orphan that will not die
  // is the difference between Retry working and Retry being dead, and the
  // log is the only place that difference is visible.
  assert.ok((halt.match(/note\(/g) || []).length >= 4,
    'each failure mode of the halt path must say why in the log');
  assert.match(halt, /"SIGNAL", arguments: \["HALT"\]/,
    'it must ask tor to quit');

  const retire = functionBody(swiftCode, 'retireRunningLocked');
  assert.match(retire, /exitingConfiguration = configuration/,
    'the configuration must outlive the run: it is what reaches the orphan');
  assert.match(retire, /haltExitingLocked\(attempt: 0\)/,
    'retiring a run must start asking it to quit');

  for (const caller of ['stop', 'failLocked']) {
    assert.match(functionBody(swiftCode, caller), /retireRunningLocked\(\)/,
      `${caller} must release the process's one tor slot`);
  }
});

test('an earlier run cannot speak for the current one', () => {
  // Generation guards: a handshake, catch-up read or failure from a run
  // that was already stopped must not resurrect or overwrite the live one.
  for (const name of ['attachLocked', 'observeLocked', 'launchWhenFreeLocked']) {
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

test('the interstitial shows what is happening, not a mute bar', () => {
  // Starting Tor is tens of seconds of nothing. A bar with no words leaves
  // the user guessing and leaves a bug report empty, which is how a device
  // where tor never opened its control port went unexplained (BUG-013).
  const widget = fs.readFileSync(
    path.join(repoRoot, 'lib/widgets/tor_bootstrap.dart'), 'utf8');
  assert.match(widget, /class _TorLogTail/,
    'the interstitial must render the recent Tor log lines');
  assert.match(widget, /animation: LogService\.instance/,
    'the tail must be live, not a snapshot taken once');
  assert.match(widget, /recent\(\{kTorLogTag, kTorDaemonLogTag\}\)/,
    'it must show the runtime transitions and what tor itself said');
  // Both branches: a user staring at a stalled bootstrap and a user staring
  // at a failure both need to see what led there.
  assert.ok((widget.match(/_TorLogTail\(\)/g) || []).length >= 3,
    'the tail belongs on the waiting screen and on the failure screen');
});

test('the plugin type-checks somewhere cheaper than a device build', () => {
  // Two selector errors reached a device build: the file no Dart or Node
  // tier compiles, in a job whose Swift is built forty minutes in and whose
  // runs are routinely cancelled by the next push before it gets there.
  // tool/swift_typecheck answers that in seconds against stub modules; it
  // is only worth anything while something actually runs it.
  const checkRel = 'tool/swift_typecheck/check.sh';
  const workflow = fs.readFileSync(
    path.join(repoRoot, '.github/workflows/build-and-test.yml'), 'utf8');
  const apple = workflow.slice(workflow.indexOf('\n  build-apple:'));
  assert.ok(apple.includes(checkRel),
    `the build-apple job must run ${checkRel}`);
  const steps = apple.slice(apple.indexOf('steps:'));
  assert.ok(steps.indexOf(checkRel) < steps.indexOf('Build IPA'),
    `${checkRel} must run before the build it front-runs`);
  assert.ok(
    fs.readFileSync(path.join(repoRoot, 'scripts/test_all.sh'), 'utf8')
      .includes(checkRel),
    `${checkRel} must also run in the local suite`);

  // A stub transcribed from one version of a header type-checks the plugin
  // against a pod that is no longer installed, and says nothing about it.
  // The stubs name the version they came from; a pod bump has to land in
  // both places or this fails.
  const iosPods = fs.readFileSync(path.join(repoRoot, 'ios/Podfile'), 'utf8');
  for (const pod of ['Tor', 'IPtProxy']) {
    const version = iosPods.match(new RegExp(`pod '${pod}', '([0-9.]+)'`))[1];
    const stubRel = `tool/swift_typecheck/stub_${pod}.swift`;
    const stub = fs.readFileSync(path.join(repoRoot, stubRel), 'utf8');
    assert.ok(stub.includes(`${pod} ${version}`),
      `${stubRel} is transcribed from a header other than ${pod} ${version}; `
      + 're-read the pinned one rather than adjusting the stub');
  }
});

test('the macOS Runner inherits the pods\' linker flags', () => {
  // IPtProxy declares `s.libraries = 'resolv'`, which reaches the app only
  // through the Pods xcconfig. The macOS Runner carried
  // `OTHER_LDFLAGS = ""` at target level, which shadows that xcconfig, and
  // the Podfile hook that rewrites the setting kept the shadow: "" is truthy
  // in Ruby, so its nil guard produced [""] rather than ["$(inherited)"].
  // The macOS link then failed on the Go runtime's res_9_ninit / res_9_nsearch
  // / res_9_nclose. iOS was spared only because its project sets no value at
  // all.
  const pbx = fs.readFileSync(
    path.join(repoRoot, 'macos/Runner.xcodeproj/project.pbxproj'), 'utf8');
  const assignments = pbx.match(/OTHER_LDFLAGS = [^;]*;/g) || [];
  assert.ok(assignments.length > 0,
    'macos/Runner.xcodeproj must set OTHER_LDFLAGS; a missing one inherits, '
    + 'but this asserts the committed value rather than its absence');
  for (const line of assignments) {
    assert.ok(line.includes('$(inherited)'),
      `macos/Runner.xcodeproj: ${line} drops the pods' linker flags`);
  }

  // Both hooks rewrite the same setting, so both have to survive a value
  // that is present but empty.
  for (const rel of ['ios/Podfile', 'macos/Podfile']) {
    const podfile = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    assert.match(podfile, /ldflags = nil if ldflags\.respond_to\?\(:empty\?\) && ldflags\.empty\?/,
      `${rel} must treat an empty OTHER_LDFLAGS as unset`);
    assert.match(podfile, /ldflags\.unshift\('\$\(inherited\)'\) unless ldflags\.include\?\('\$\(inherited\)'\)/,
      `${rel} must keep $(inherited) in the flags it writes back`);
  }
});

test('one funnel opens the control connection, and it asks isConnected', () => {
  // TORController(controlPortFile:) connects inside its initializer, and
  // connect() on an already-connected controller returns NO without writing
  // an error -- which Swift raises as _GenericObjCError error 0. A second
  // connect() therefore reports every success as that failure, which is what
  // kept the runtime from ever reaching `up` on a device whose tor was
  // running and listening the whole time. The rule is structural because no
  // tier here runs the plugin: construct in one place, and decide there by
  // isConnected rather than by a throw.
  const body = functionBody(swiftCode, 'connectedController');
  for (const call of ['TorController(controlPortFile:', '.connect()']) {
    const inFile = swiftCode.split(call).length - 1;
    const inFunnel = body.split(call).length - 1;
    assert.equal(inFunnel, 1, `${swiftRel}: connectedController must ${call}`);
    assert.equal(inFile, inFunnel,
      `${swiftRel}: ${call} appears ${inFile - inFunnel} time(s) outside `
      + 'connectedController; every control connection goes through it');
  }
  assert.ok(body.includes('isConnected'),
    `${swiftRel}: connectedController must decide on isConnected, not on a throw`);
});

test('the Tor scenario reports before the tier spends its budget', () => {
  // It rode the alphabetical loop, 17th of 19, inside a step capped at 45
  // minutes that already spends ~36 on the other files -- and every push
  // cancels the job before then. It therefore never returned a verdict on
  // any of the bugs above: each one was reported from a device first. Its
  // own step, run first, is what makes it a gate rather than a hope.
  const workflow = fs.readFileSync(
    path.join(repoRoot, '.github/workflows/build-and-test.yml'), 'utf8');
  const apple = workflow.slice(workflow.indexOf('\n  build-apple:'));
  const own = apple.indexOf('flutter test integration_test/tor_test.dart');
  const loop = apple.indexOf('for t in integration_test/*_test.dart');
  assert.ok(own > 0, 'the Tor scenario must have a step of its own');
  assert.ok(loop > 0, 'the macOS tier loop must still be there');
  assert.ok(own < loop, 'the Tor scenario must run before the tier loop');
  assert.match(apple.slice(loop),
    /\[ "\$\(basename "\$t"\)" = "tor_test\.dart" \] && continue/,
    'the loop must skip what the step above already ran');

  // The network opt-in belongs to that step: it is what turns "never
  // reached the network" from a skip into a failure (TOR-021).
  const step = apple.slice(apple.lastIndexOf('- name:', own), own);
  assert.match(step, /WEBSPACE_TOR_NETWORK: '1'/,
    'the Tor step must carry the network opt-in');
});

test('both Apple targets register the plugin where the engine exists', () => {
  // The macOS registration sat behind
  // `NSApplication.shared.windows.first` in the app delegate, which returns
  // quietly when the window is not up yet -- and under `flutter test -d
  // macos` it is not. The tier's first run answered every Tor call with
  // MissingPluginException. It now registers beside RegisterGeneratedPlugins.
  const mac = fs.readFileSync(
    path.join(repoRoot, 'macos/Runner/MainFlutterWindow.swift'), 'utf8');
  const generated = mac.indexOf('RegisterGeneratedPlugins(');
  const tor = mac.indexOf('TorControllerPlugin(');
  assert.ok(generated > 0 && tor > generated,
    'macos/Runner/MainFlutterWindow.swift must register the Tor plugin after '
    + 'the generated ones, where the engine is known to exist');
  assert.match(mac, /private var torControllerPlugin/,
    'the window must hold the plugin; a released one stops answering');

  const delegate = fs.readFileSync(
    path.join(repoRoot, 'macos/Runner/AppDelegate.swift'), 'utf8');
  assert.ok(!delegate.includes('TorControllerPlugin'),
    'macos/Runner/AppDelegate.swift must not register it a second time, '
    + 'behind a window lookup that can silently skip');

  // iOS keeps its own: there the delegate owns a window by the time
  // didFinishLaunching returns, and it is the shipping path.
  const ios = fs.readFileSync(
    path.join(repoRoot, 'ios/Runner/AppDelegate.swift'), 'utf8');
  assert.match(ios, /torControllerPlugin = TorControllerPlugin\(/,
    'iOS must still register the plugin');
});
