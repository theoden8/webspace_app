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
const { read, code, blockAfter, methodBody } = require('./helpers/source');

const swift = code(read('ios/Runner/TorControllerPlugin.swift'));
const engine = code(read('lib/services/tor_engine.dart'));
const service = code(read('lib/services/tor_service.dart'));
const workflow = read('.github/workflows/build-and-test.yml');

test('tor\'s control channel is a Unix socket, the kind a suspension spares', () => {
  const launch = blockAfter(swift, 'func launchLocked(');
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
  const cycle = blockAfter(swift, 'func cycleNetwork(');
  const off = cycle.indexOf('"DisableNetwork", "value": "1"');
  const on = cycle.indexOf('"DisableNetwork", "value": "0"');
  assert.ok(off > 0 && on > off,
    'DisableNetwork 1 closes the dead listener, then 0 opens a fresh one');
  const reopen = blockAfter(swift, 'func reopenListeners(');
  assert.match(reopen, /publishLocked\(state: "up"/,
    'the new endpoint is published, so every Tor-bound site rebinds');
  assert.match(reopen, /OneShotResult\(result\)/,
    'the call answers exactly once, whatever tor does (BUG-018)');
});

test('a reopen brings the bridge transport back with tor', () => {
  // BUG-013 attempt 14. The transport's SOCKS listener is a loopback TCP
  // socket in the app, so the suspension that kills tor's listener kills
  // it too. A reopen of tor's listener alone came back `up` with every
  // bridge dialled through the dead port: no circuit, pages loading
  // forever, nothing on screen. The engine's half is in tor_engine_test.
  const reopen = blockAfter(engine, 'Future<void> _reopen(');
  const restart = reopen.indexOf('restartTransport(');
  const lines = reopen.indexOf('torBridgeOptions(bridges, transportPort: port)');
  assert.ok(restart > 0 && lines > restart,
    'the transport starts again first, and tor gets lines naming its new port');

  const start = blockAfter(swift, 'private func startTransport(');
  assert.match(start, /if restart, self\.startedTransports\.contains\(name\) \{\s*controller\.stop\(name\)/,
    'a restart stops the dead transport, or start answers its old port');
  assert.match(swift, /case "restartTransport":[\s\S]{0,200}restart: true/);

  const cycle = blockAfter(swift, 'func cycleNetwork(');
  assert.match(cycle,
    /bridges \+ \[\["key": "DisableNetwork", "value": "0"\]\]/,
    'tor reads ClientTransportPlugin only with its network on (options_act), '
    + 'so the bridge lines ride the SETCONF that turns it back on');
  assert.match(blockAfter(swift, 'private func reopenListeners('),
    /cycleNetwork\(live, bridgeOptions: bridgeOptions\)/,
    'the lines Dart sent reach the SETCONF');

  // Tor.framework's setConfs joins key=value unquoted, and a bridge line
  // has spaces; a raw line break would end the command and start another.
  const quoted = blockAfter(swift, 'static func quotedConfs(');
  assert.match(quoted, /\$0 == "\\n" \|\| \$0 == "\\r"/);
  assert.match(quoted, /"\\"\\\(escaped\)\\""/);
});

test('sites wait for a circuit after a reopen, and say so', () => {
  // DisableNetwork closed every relay connection; until tor builds a new
  // circuit a page bound to the fresh listener only spins.
  assert.match(blockAfter(swift, 'private func circuitEstablished('),
    /\["status\/circuit-established"\]/);
  const settle = blockAfter(engine, 'Future<void> _settle(');
  const circuit = settle.indexOf('_circuitBuilt(up)');
  const pin = settle.indexOf('_applyPin(up)');
  assert.ok(circuit > 0 && pin > circuit,
    'the circuit before the pin, in the one queue that publishes up');
  assert.match(blockAfter(engine, 'void _publishUp('),
    /if \(_circuitOwed != null\)/,
    'a reopen\'s listener is not published until the circuit is in');
  assert.match(blockAfter(engine, 'Future<bool> _reopenIfDead('),
    /_circuitOwed = Object\(\);/);
});

test('DisableNetwork finds no conflux leg to relaunch', () => {
  // tor relaunches a closed leg of an unlinked conflux set without checking
  // DisableNetwork, the connect is refused, and the guard is then refused for
  // 60 s (OR_CONNECT_FAILURE_LIFETIME): a runtime that is up and carries
  // nothing. Seen on the macOS probe. Conflux off from launch is the only
  // state in which no such leg exists.
  assert.match(swift, /static let confluxEnabledValue = "0"/);
  const launch = blockAfter(swift, 'func launchLocked(');
  assert.match(launch, /"ConfluxEnabled": Self\.confluxEnabledValue/,
    'tor must start with conflux off, not have it turned off later');
  assert.ok(!/"ConfluxEnabled",\s*"value":\s*"(auto|1)"/.test(swift),
    'nothing may turn conflux back on while the runtime lives');
  const probe = code(read('integration_test/tor_suspension_probe.dart'));
  assert.match(probe, /Tried to open a socket with DisableNetwork set/,
    'the macOS probe fails on the symptom itself');
});

test('the listener is asked on every way back into the app', () => {
  const production = blockAfter(service, 'static TorService _production(');
  assert.match(production, /socksProbe: createTorSocksProbe\(\)/,
    'the engine needs the probe, or revive() asks nothing');
  assert.match(production, /addObserver\(_TorResumeWatch\(service\)\)/,
    'registered with the singleton, so no screen has to be up for it');
  const watch = blockAfter(service, 'void didChangeAppLifecycleState(');
  assert.match(watch, /AppLifecycleState\.resumed[\s\S]*revive\(\)/,
    'a return to the foreground asks the listener');

  const wake = methodBody('wake', { file: 'lib/controllers/background_sites_controller.dart' });
  const revive = wake.indexOf('TorService.instance.revive()');
  assert.ok(revive > 0 && revive < wake.indexOf('_wakeEngine.wake('),
    'a background wake resumes the process without a resumed event, so it '
    + 'asks before reloading anything');
});

test('a resume mid-bootstrap and a slept-through deadline are both handled', () => {
  assert.match(blockAfter(engine, 'Future<void> revive('), /_checkNextUp = true/,
    'a runtime not up yet has its listener asked when it comes up');
  assert.match(blockAfter(engine, 'void _armBootstrapTimeout('), /kTorSuspendedSlack/,
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
