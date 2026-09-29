// Tor outlives the app being suspended (TOR-024, BUG-013 attempt 11).
//
// iOS defuncts every socket a suspended app owns except Unix-domain ones,
// and a phone came back from one with tor unreachable for the rest of the
// process. The fix has four parts in four files, and dropping any one of
// them brings the dead end back without a test failing anywhere else: only
// the macOS probe runs the real thing, an hour into CI. So each part is
// pinned here.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');
const code = (src) => src.replace(/^\s*\/\/.*$/gm, '');

const swift = code(read('ios/Runner/TorControllerPlugin.swift'));
const engine = code(read('lib/services/tor_engine.dart'));
const service = code(read('lib/services/tor_service.dart'));
const main = code(read('lib/main.dart'));
const workflow = read('.github/workflows/build-and-test.yml');

function body(src, signature) {
  const at = src.indexOf(signature);
  assert.ok(at >= 0, `missing ${signature}`);
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(open, i + 1);
  }
  throw new Error(`unbalanced braces after ${signature}`);
}

test('tor\'s control channel is a Unix socket, the kind a suspension spares', () => {
  const launch = body(swift, 'func launchLocked(');
  const socket = launch.indexOf('config.controlSocket = socket');
  assert.ok(socket > 0, 'launchLocked must give tor a ControlSocket');
  assert.match(launch, /controlSocketURL\(in: NSTemporaryDirectory\(\)\)/,
    'under tmp: a container\'s Library/Caches path does not fit sun_path');
  assert.match(launch, /posixPermissions: 0o700/,
    'tor refuses a control socket in a directory others can list');
  const tcp = launch.indexOf('config.autoControlPort = true');
  assert.ok(tcp > socket,
    'the TCP control port is only the fallback for a path that does not fit');
  assert.match(swift, /let kSunPathSize = 104\b/,
    'sizeof(sockaddr_un.sun_path) on Darwin');
});

test('a dead listener is reopened, not reconfigured', () => {
  // SETCONF SocksPort keeps a listener tor believes is running
  // (socksPortValue says why); only DisableNetwork closes it.
  const cycle = body(swift, 'func cycleNetwork(');
  assert.match(cycle, /for value in \["1", "0"\]/,
    'DisableNetwork 1 closes the dead listener, 0 opens a fresh one');
  assert.match(cycle, /"DisableNetwork"/);
  const reopen = body(swift, 'func reopenListeners(');
  assert.match(reopen, /publishLocked\(state: "up"/,
    'the new endpoint is published, so every Tor-bound site rebinds');
  assert.match(reopen, /OneShotResult\(result\)/,
    'the call answers exactly once, whatever tor does (BUG-018)');
});

test('the listener is asked on every way back into the app', () => {
  const production = body(service, 'static TorService _production(');
  assert.match(production, /socksProbe: createTorSocksProbe\(\)/,
    'the engine needs the probe, or revive() asks nothing');
  assert.match(production, /addObserver\(_TorResumeWatch\(service\)\)/,
    'registered with the singleton, so no screen has to be up for it');
  const watch = body(service, 'void didChangeAppLifecycleState(');
  assert.match(watch, /AppLifecycleState\.resumed[\s\S]*revive\(\)/,
    'a return to the foreground asks the listener');

  const wake = body(main, 'Future<void> _backgroundWake(');
  const revive = wake.indexOf('TorService.instance.revive()');
  assert.ok(revive > 0 && revive < wake.indexOf('_wakeEngine.wake('),
    'a background wake resumes the process without a resumed event, so it '
    + 'asks before reloading anything');
});

test('a resume mid-bootstrap and a slept-through deadline are both handled', () => {
  assert.match(body(engine, 'Future<void> revive('), /_checkNextUp = true/,
    'a runtime not up yet has its listener asked when it comes up');
  assert.match(body(engine, 'void _armBootstrapTimeout('), /kTorSuspendedSlack/,
    'a deadline firing long after it was due is a suspension, not a failure');
});

test('the macOS tier defuncts a live tor\'s sockets and expects it back', () => {
  const probeRel = 'integration_test/tor_suspension_probe.dart';
  assert.ok(!probeRel.endsWith('_test.dart'),
    'not a flutter test: the defunct takes the VM service connection');
  const probe = code(read(probeRel));
  assert.match(probe, /'pid_shutdown_sockets'/);
  assert.match(probe, /handleAppLifecycleStateChanged\(AppLifecycleState\.resumed\)/,
    'the resume goes through the app\'s own lifecycle path');
  assert.match(probe, /verdict:/);

  const apple = workflow.slice(workflow.indexOf('\n  build-apple:'));
  const at = apple.indexOf('- name: Run the Tor suspension probe');
  assert.ok(at > 0, 'the probe needs a step of its own');
  const step = apple.slice(at, apple.indexOf('\n      - name:', at + 1));
  assert.match(step, /if: success\(\) \|\| failure\(\)/,
    'it must run even when the tier ahead of it went red');
  assert.match(step, /timeout-minutes: \d+/);
  assert.match(step, /-t integration_test\/tor_suspension_probe\.dart/);
  assert.match(step, /sudo "\$helper" "\$pid"/,
    'the root helper answers when the sandbox refuses the call on its own pid');
});
