# BUG-013: Tor never reaches `up`, and the runtime is unusable afterwards

**Status:** open on iOS. **Closed on macOS as of attempt 10:** the tier runs the
plugin and tor bootstraps to 100% and reaches `up`, in CI and on local hardware.
Every mechanism in this file was inferred from reading Tor.framework's source and
first observed on a phone; none has been watched on one. The class stays open until
something runs the plugin on iOS — see open gaps.
**Platform:** iOS. The same source builds for macOS, where the integration tier runs
it and it works; the two differ in data-dir sandboxing, app-lifecycle suspension,
memory pressure and release-vs-debug assert behaviour, so a macOS pass is evidence
about the control-port conversation and not about the phone.
**Spec:** [tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md)
TOR-018 (the bootstrap says what it is doing), TOR-019 (one control connection, read
before subscribing), TOR-020 (one tor per process; a stop asks it to exit), TOR-024
(tor outlives the app being suspended).
**Tests:** `integration_test/tor_test.dart` (the only tier that runs the plugin, macOS
only), `integration_test/tor_suspension_probe.dart` (the same runtime with its sockets
defuncted, run as the Runner's entrypoint), `test/js/tor_bootstrap_observability.test.js`
and `test/js/tor_suspension.test.js` (structural) and
`tool/swift_typecheck/check.sh` (compiles it, runs nothing). Every other Tor test drives
a fake `TorRuntime`.

## Symptom

A site pinned to Tor sits on the bootstrap interstitial and never loads. What the user
sees has differed per attempt — a silent spinner, then "Tor stopped unexpectedly", then
"The previous Tor is still running" — but the state is the same: the runtime never
reaches `up`, and after the first failure nothing the user can do from inside the app
recovers it.

## Root mechanism (the invariant behind every instance)

**The plugin's conversation with tor is policy, and policy written where nothing runs it
is a guess.** Every instance so far is a rule about *timing or ordering* on the control
port — when to read, how long to wait, who may answer — that was written from reading
Tor.framework's source rather than from watching it run:

- the framework hands command replies and asynchronous events to one observer list, so
  *when* a read is issued decides whether an event answers it;
- tor opens its control port when the device lets it, so *how long* to wait is a property
  of the phone, not of the code;
- only one tor may run per process, so *who* can ask an orphan to exit decides whether the
  feature works again at all.

This repo's own rule (CLAUDE.md, "Logic engine vs rendering engine") puts exactly this
kind of decision in a pure Dart engine and leaves the platform call site mechanical. The
Tor lifecycle policy lives in Swift instead, where no tier executes it: the Dart tests
drive a fake `TorRuntime` whose `stop()` is `async {}`, and the structural gates match
text, so they encode the same assumption the code does. **A test derived from an
assumption cannot falsify it.**

## Fix attempts (chronological)

### Attempt 1 — The read that an event answered
**Date:** 2026-09-15 · **Commit:** 08865c4 · **Files:** `ios/Runner/TorControllerPlugin.swift`
**What it did:** every control-port read (`net/listeners/socks`, `status/bootstrap-phase`)
moved to the attach, before `SETEVENTS`, on a connection that is still quiet, and
`addObserver(forCircuitEstablished:)` was dropped for the plugin's own status observer.
**Why:** `getInfoForKeys`'s observer answers the first line it is handed and then
unregisters. With `STATUS_CLIENT` events already flowing, a bootstrap event could answer
the SOCKS read (reported back as empty, which reads as "no usable SOCKS listener") or
answer the read the framework's circuit-established observer issues, after which that
observer removes itself and `CIRCUIT_ESTABLISHED` is never delivered — a bootstrap that
had already succeeded sat on the interstitial until the 90-second timeout.
**Why it was partial:** it fixed the reads that happen *after* the control port answers.
It never asked whether the app reaches the control port in the first place, which is
attempt 2.

### Attempt 2 — The control port had 1.5 seconds to answer
**Date:** 2026-09-15 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`test/js/tor_bootstrap_observability.test.js`
**What it did:** the attach was a 1.0s delay followed by three `connect()` attempts 0.25s
apart, all on a queue that sleeps — about 1.5 seconds in total, after which the run failed
with "Could not reach the Tor control port". It is now a bounded poll scheduled from the
state queue (0.5s × 60, so 30 seconds), each attempt re-checking the run it belongs to and
the thread it is waiting on, logging every 10th attempt, and treating an unreadable cookie
as the same timing artifact as a refused connection. The gate asserts the budget stays
above 20 seconds and that the exit wait outlasts the shutdown loop.
**Why:** how long tor takes to write its port file and accept a connection is a property
of the device — a cold start reading geoip on a busy phone takes seconds. The old budget
failed runs that would have been fine a moment later, and (before BUG-007 attempt 7) left
behind a tor nobody could talk to, which is how the first failure became permanent.
**Why it was partial:** the number is still a guess, just a generous one, and nothing
measures what a real device needs. The failure it produces is still terminal for the run
rather than a longer wait with the interstitial saying so. And it shares the class's open
gap: no tier on iOS runs any of this.

### Attempt 3 — Nothing could see what tor was doing
**Date:** 2026-09-15 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`lib/widgets/tor_bootstrap.dart`, `lib/services/log_service.dart`,
`test/js/tor_bootstrap_observability.test.js`
**What it did:** a device log finally arrived and said something neither of the first two
attempts had considered: tor's thread starts, stays alive, and never writes its
control-port file at all. Every diagnostic built so far reads the control port, so all of
them were blind, and the framework makes it worse —
`TORController(controlPortFile:)` parses the file *at init*, so a missing file yields a
controller with a nil host whose `connect()` fails with an unset error, surfacing as
"The operation couldn't be completed. (Foundation._GenericObjCError error 0.)" forever.
tor now writes `--Log notice file <dataDir>/tor.log`, which the plugin tails into the app
log; the attach notes say whether the port file was written and whether the thread is
still executing; and the bootstrap interstitial renders the last few lines live, on both
the waiting and the failure screen, instead of a mute bar.
**Why:** the user could not tell a slow bootstrap from a dead one, and neither could I:
three rounds of fixes were inferred from reading Tor.framework rather than from anything
the device said. A log file is a deviation from TOR-018's "never on disk", taken
deliberately: the control port cannot describe a tor that never opens one. It is
truncated at start, removed at stop, and `SafeLogging 1` still applies.
**Why it was partial:** it explains rather than fixes. tor still never opens its control
port on that device and the cause is still unknown; this attempt exists so the next report
carries tor's own words. The log file is also new state on disk, and the control-port log
subscription it replaces is gone, so a future change that wants both has to reconcile them.


### Attempt 4 — The file nothing compiles
**Date:** 2026-09-15 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`tool/swift_typecheck/`, `.github/workflows/build-and-test.yml`, `scripts/test_all.sh`,
`test/js/tor_bootstrap_observability.test.js`
**What it did:** attempt 3 shipped `controller.listenForEvents(_:completion:)`, which
Tor.framework renamed to `listen(forEvents:completion:)`; the user hit it in Xcode. A
second selector error had reached a device build the same way. `tool/swift_typecheck/`
type-checks the plugin against hand-transcribed stub modules (`Flutter`, `Tor`,
`IPtProxy`) using any Swift 5 toolchain, in about a second; it is the first step of the
Apple CI job and part of `scripts/test_all.sh`, and skips when no `swiftc` is installed.
The gate asserts both call sites and that each stub still names the pod version the
Podfile pins.
**Why:** CI does build this file — forty minutes into the one job that compiles Swift,
and `cancel-in-progress` means the next push cancels the run before it gets there. Every
build-apple run on this branch was cancelled, so the error reached a person instead. The
cost of a wrong selector should be seconds, not a TestFlight round trip.
**Why it was partial:** type-checking is not execution — it catches selectors, labels and
types, and nothing about timing, ordering or lifetime, which is every bug above it in this
file. A stub is also only as good as the header it was transcribed from: it can agree
with a call the real framework rejects. It narrows open gap 1 to its important half.


### Attempt 5 — Every success was being read as a failure
**Date:** 2026-09-15 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`integration_test/tor_test.dart`, `test/js/tor_bootstrap_observability.test.js`,
spec TOR-019 + TOR-021
**What it did:** a device log arrived where tor *had* written its port file and its
thread was running, and the attach still failed 60 times over 30 seconds, each with
"The operation couldn't be completed. (Foundation._GenericObjCError error 0.)", and the
orphan halt then failed 30 more times with the same string. Reading
`TORController.m` at the pinned tag explains all of it:
`initWithControlPortFile:` ends in `initWithSocketHost:port:`, which calls
`[self connect:nil]` **inside the initializer**, and `connect:` opens with
`if (_channel) { return NO; }` — a failure with no error written, which Swift raises as
that `_GenericObjCError`. So the plugin's own `try controller.connect()` reported
failure precisely when the framework had already connected. Both call sites now go
through one funnel that asks `isConnected` and only calls `connect()` when the
initializer did not already do it.
**Why:** the same opaque error is also what an unparseable port file produces (in a
release build both `NSAssert`s are compiled out, so a nil host reaches `connect:`'s
final `return NO`), which is why attempt 3 read it as "tor never wrote its port file".
One error string, two opposite causes, and the plugin was choosing the wrong one every
time.
**Why it was partial:** it fixes the reads this plugin makes. The framework will answer
any other already-satisfied call the same way, and nothing here checks that class
except the funnel gate. The macOS tier that would have caught it is still the only
executor, and it had not completed a single run when this was written.


### Attempt 6 — The tier's first verdict: nothing was listening on macOS
**Date:** 2026-09-15 · **Files:** `macos/Runner/MainFlutterWindow.swift`,
`macos/Runner/AppDelegate.swift`, `test/js/tor_bootstrap_observability.test.js`
**What it did:** hoisted into its own step (see gap 1), `integration_test/tor_test.dart`
returned a verdict for the first time since it was written, and failed both scenarios
with `MissingPluginException(No implementation found for method setTorrcOptions on
channel org.codeberg.theoden8.webspace/tor)`. The macOS registration lived in
`AppDelegate.registerShareChannelOnMainWindow()`, behind
`guard let window = NSApplication.shared.windows.first ... else { return }` — a lookup
that returns quietly when the window is not up, which under `flutter test -d macos` it
is not. It now registers in `MainFlutterWindow.awakeFromNib()`, on the line after
`RegisterGeneratedPlugins`, where the engine is known to exist.
**Why:** the tier is the only thing that runs this plugin, and it could not have passed
in the state it was written in — the runtime it was meant to drive was never reachable
from it. That is the cost of adding a tier and never watching it run.
**Why it was partial:** it fixes the Tor channel. `ShortcutsPlugin` and the share
channel register behind the same guard and are therefore equally absent under the
harness; nothing there fails loudly, because every consumer treats a missing channel as
"nothing pending". Out of this change's scope, and now written down.


### Attempt 7 — The tier reached the runtime and reported nothing
**Date:** 2026-09-15 · **Files:** `integration_test/tor_test.dart`,
`.github/workflows/build-and-test.yml`
**What it did:** with the plugin registered (attempt 6), the step got further than
ever: the app launched, `[Tor/info] Starting tor.` reached the log — the runtime is
reachable from the tier for the first time — and then both scenarios ticked green
within 120ms of each other and `flutter test` ended with "No tests were found.",
"0 tests passed" and exit 79. Neither body can complete in 120ms; both left through
a branch. The file could not say which, so it now traces platform, availability,
`torRequired` and the environment variable at `setUpAll`, marks the start and end of
each scenario, and — the substantive change — **fails instead of skipping when the
runtime reports unavailable on an Apple build**, where the plugin is supposed to
exist. The step names an exit 79 for what it is.
**Why:** a skip is how a tier that reaches nothing reports success, which is the
failure mode this whole file is about. The previous availability check stood down
politely on the one platform where standing down is the bug.
**Why it was partial:** it is diagnosis, not a fix — the reason both scenarios left
early is still unknown, and the next run is what says it. "Failed to foreground app;
open returned 1" appears just before the launch and has not been ruled in or out.


### Attempt 8 — The tier's app was aborting, not skipping
**Date:** 2026-09-15 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`ios/Podfile`, `macos/Podfile`, `test/js/tor_bootstrap_observability.test.js`
**What it did:** the tier printed a macOS crash report this time: `Webspace`,
`EXC_CRASH (SIGABRT)`, launched 19:49:35 and dead 19:49:46 — the app aborted ten
seconds in, which is what "two ticks and no tests were found" was all along.
Tor.framework asserts two things this app does deliberately:
`NSAssert(host, @"Provided file doesn't seem to be a valid control port file...")`
in `initWithControlPortFile:`, and `NSAssert(_thread == nil, @"There can only be one
TORThread per process")` in `TORThread`, whose static is set once and never cleared.
A release build compiles both out — which is why the shipped app attaches and
restarts — and a debug build, which is every `flutter test -d macos`, raises and
aborts. The plugin now reads and parses the port file itself before handing it to
the framework (rejecting a missing, empty or half-written one), and both Podfiles
compile the pod's assertions out with `NS_BLOCK_ASSERTIONS=1`, in the Tor target
only.
**Why:** the attach loop builds a controller on its first attempt, before tor has
written anything, and the restart scenario builds a second thread by design. Neither
is an error; the framework's asserts are simply stricter than its release behaviour,
and the tier is the only place they are live.
**Why it was partial:** it stops the abort. Whether the scenarios then pass is the
next run's answer, and the asserts are compiled out rather than satisfied — a real
second concurrent TORThread would now be silent in debug too, which is what the
generation guard and exit watch (attempt 6 of BUG-007) exist to prevent.


### Attempt 9 — tor runs once per process, and everything stopped it
**Date:** 2026-09-16 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`lib/services/tor_engine.dart`, `lib/screens/app_settings.dart`,
`test/tor_engine_test.dart`, `test/js/tor_bootstrap_observability.test.js`,
`lib/l10n/app_*.arb`
**What it did:** the macOS tier finally ran the restart scenario, and tor answered
for itself:

```
[Tor/info] Control port answered after 0s; authenticating.
[TorLog/warning] Failed to confirm worker threads' start up after timeout.
[TorLog/warning] tor_bug_occurred_: Bug: src/lib/evloop/workqueue.c:716:
    threadpool_new: This line should not have been reached.
    ... cpuworker_init + 112 / run_tor_main_loop + 204 / tor_run_main + 4660
[TorLog/error] Can't create worker thread pool
[Tor/error] State: error(bootstrapTimeout: Tor did not finish bootstrapping in time.)
```

The orphan-halt work of attempts 6-8 was right about the *slot*: the previous thread
does exit and the data-directory lock is released. It was wrong about what that buys.
tor's own global state outlives `tor_run_main`, so the second entry finds the
cpuworker pool already built, trips its `BUG()`, and runs without workers — after
which the bootstrap simply never progresses and the 90-second deadline calls it a
network failure. `TORThread`'s own `NSAssert(_thread == nil, "There can only be one
TORThread per process")` was saying the same thing from the other side; it was read
as "not two at a time" when it means "not twice".

Everything in the app stopped tor as a matter of routine: the 60-second idle debounce
after the last Tor site was released, the bootstrap deadline, Retry, and (added
earlier in this PR) a change to the destination-isolation setting. Each one burned the
process's only launch and left a runtime that could never come back — which is
precisely the reported *"sometimes I have to restart the app for the Tor proxy to
start working"*. So: the plugin now refuses a second launch with a named error
instead of entering `tor_run_main` again; releasing the last holder no longer stops
the runtime; the bootstrap deadline reports without tearing down; Retry re-arms the
wait instead of stop-then-start; and the isolation setting is recorded for the next
start, with the hint saying so in all 67 locales.

A live `SETCONF SocksPort="auto IsolateSOCKSAuth IsolateDestAddr"` was tried first and
rejected on reading tor: `retry_listener_ports` treats a `CFG_AUTO_PORT` request as
matching any existing listener on that address and keeps it ("This listener is already
running"), and the isolation flags live on the listener's `entry_cfg`, copied once in
`connection_listener_new`. tor answers `250 OK` and nothing changes. A SETCONF that
looks applied is worse than one that is refused.
**Why:** a failure the user can act on beats a three-minute wait that names the wrong
cause. And a stop is only worth making when there is something to start afterwards.
A first cut of this shipped a Retry that broke a working runtime: it published
`starting` and armed the deadline before calling start, and start is a no-op
while tor is alive, so nothing moved the status back and 90 seconds later the
engine reported a bootstrap failure against a tor that was connected. The tier
caught it in 149 seconds. Retry on an `up` runtime now does nothing at all.
**Why it was partial:** the ceiling is upstream and stays. Tor is now unavailable for
the rest of the session after any genuine teardown — a bootstrap that really cannot
finish still leaves a tor running and retrying, and a bridge configuration edited
mid-session still needs an app restart to apply. Neither is fixed here; both are now
said out loud instead of hanging. `integration_test/tor_test.dart:252` ("a restart
inside the handshake window still comes back") asserts the behaviour this attempt
removes and is rewritten to assert the refusal instead.


### Attempt 10 — The macOS tier returned a verdict, and it is `up`
**Date:** 2026-09-22 · **Commit:** (this one) · **Files:** none — a measurement, not a fix.

Gap 1 said the macOS tier had never returned a verdict and that every failure here was
first seen on a device. That half is now answered. CI run 35729775900 ran
`the runtime bootstraps, says what it is doing, and restarts` with
`WEBSPACE_TOR_NETWORK=1` and passed, and the same scenario was then run on local Apple
hardware (macOS 15.7.3, arm64, debug build) with the same result:

```
[Tor/info] Control port authenticated.
[Tor/info] Bootstrap was at 0% when the control port attached.
[Tor/info] State: bootstrapping(5%, conn) ... (75%, enough_dirinfo)
[Tor/info] State: bootstrapping(90%, ap_handshake_done)
[Tor/info] State: bootstrapping(100%, done)
[Tor/info] Connected. SOCKS listener on 127.0.0.1:51952.
[Tor/info] State: up(127.0.0.1:51952)
```

Both scenarios passed, the restart included. So on macOS the control-port sequence,
the attach funnel, `NS_BLOCK_ASSERTIONS=1` on the pod and the log tail are good
enough, and attempts 1, 2, 5, 8 and 9 are confirmed on that platform rather than
merely argued.

**Why it is partial, and it is the important half.** It says nothing about iOS, which
is the platform this bug is about and where every one of its instances was first seen.
macOS and iOS compile the same `TorControllerPlugin.swift` but differ in data-dir
sandboxing, lifecycle suspension, memory pressure and whether `NSAssert` aborts. The
control-port budget attempt 2 set is still a number nobody has measured against a real
phone, on cellular or cold.

It also exercises only the happy path plus a restart. A control port that opens late —
the mechanism of attempt 2 — is still simulated nowhere (gap 4).

### Attempt 11 — A suspension killed every socket tor had but its thread
**Date:** 2026-09-28 · **PR:** #627 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`lib/services/tor_engine.dart`, `lib/services/tor_service.dart`,
`lib/services/tor_socks_probe_io.dart`, `lib/main.dart`,
`integration_test/tor_suspension_probe.dart`, `tool/tor_suspension/defunct_sockets.c`

**What happened.** A device log from 2026-09-25: a background refresh launched the app
at 07:25 with the phone locked, which started tor, and iOS suspended the app seconds
later. At 07:40 the next wake ran the 90-second bootstrap deadline first ("Tor did not
finish bootstrapping in time", fifteen minutes after it was armed), and when the app
came to the foreground the plugin could neither reach tor's control port nor ask it to
exit: "The previous Tor is still running". Attempt 9 had made that a named dead end
rather than a crash, and it stayed a dead end: tor runs once per process.

**Mechanism.** iOS defuncts a suspended app's sockets through the kernel's
`socket_defunct`, which calls `sosetdefunct(..., noforce=TRUE)` and so skips any socket
marked SOF_NODEFUNCT. `socreate` marks every PF_LOCAL socket that way ("Don't mark Unix
domain or system eligible for defunct by default"), and only root may mark any other
(`SO_DEFUNCTOK`). So the loopback TCP control port, the connection to it, tor's SOCKS
listener and its relay connections all died, and tor's thread came back running with
nothing anyone could reach. Onion Browser avoids the same thing by stopping tor when its
background time runs out and starting another on return, which is the second
`tor_run_main` attempt 9 found never bootstraps.

**What it did.**
- tor's control channel is a Unix-domain socket (`ControlSocket`, under `tmp/tor/`, a
  0700 directory, with a TCP fallback that says so when the path would not fit a
  `sockaddr_un`). It survives the suspension, and so does the connection to it.
- On every return to the foreground, and at the start of a background wake, the engine
  asks the SOCKS listener for a SOCKS5 greeting. A dead one is reopened with
  `DisableNetwork 1` then `0` over the surviving channel, which closes every listener
  and relay connection but the control ones and opens the listeners again; the new port
  is published as `up` and every Tor-bound site rebinds (`torBindingChanged`). A return
  mid-bootstrap has the listener asked at the next `up`.
- The bootstrap deadline starts its window over when it fires long after it was due,
  instead of reporting a bootstrap the app slept through.

**Why.** Keeping the one tor alive is the only recovery a single-launch process has, and
the kernel leaves exactly one kind of socket standing to reach it with. A plain
`SETCONF SocksPort` would not do: tor keeps a listener it believes is running (see
`setSocksIsolation`).

**Reproduced** on the macOS tier by `integration_test/tor_suspension_probe.dart`, which
calls `pid_shutdown_sockets(pid, SHUTDOWN_SOCKET_LEVEL_DISCONNECT_ALL)` on the app, the
same kernel call, and then injects the resume. It cannot run under `flutter test`: the
defunct takes the VM service connection that drives the app, so the workflow builds it
as the Runner's entrypoint and reads its verdict off stderr. Before the fix (run
36420085762, tests only): the app sandbox refused the call on its own pid (EPERM) and
the root helper made it; `kernel: tcp=dead unix=alive`; tor's SOCKS listener and its
TCP control connection both stopped answering; and after the resume the runtime still
reported `up` on the dead port. After it (run 36430625500, 404df43): the same kernel
split, and this time the Unix control connection answered after the defunct, the resume
published a new SOCKS port (50597 to 50608), a request through it left from a Tor exit,
and the probe's verdict was `recovered`.

**Why it is partial.** The probe defuncts the sockets but does not freeze the process:
tor's timers, its view of the clock and a bootstrap caught mid-handshake behave on macOS
as they would on a phone that was never suspended. Nothing has run it on an iOS device.
The TCP fallback, if a container path is ever too long, is as dead after a suspension
as before, and says so in the log.

### Attempt 12 — The reopen left tor's guard refused for a minute
**Date:** 2026-09-29 · **PR:** #648 · **Files:** `ios/Runner/TorControllerPlugin.swift`,
`integration_test/tor_suspension_probe.dart`, `test/js/tor_suspension.test.js`

**What happened.** The macOS probe failed on run 36559429018 (the re-run of PR #648's
Apple job). Every step of attempt 11 held: the defunct killed tor's TCP listener, the
Unix control connection survived, and the resume published a new SOCKS port (50433 to
50444) that answered the greeting. Then the request through it hung for its full 90
seconds; the passing runs of the same probe finished in about 6. Only the failing run's
tor log carries `Tried to open a socket with DisableNetwork set`, with a stack through
`conflux_circuit_has_closed -> conflux_launch_leg -> circuit_establish_circuit_conflux`.

**Why.** Read in tor 0.4.9.11, the version the pod ships. `DisableNetwork 1` marks every
non-control connection for close; a circuit on one of them that was a leg of a conflux
set that had not linked yet closes, and `unlinked_circuit_closed` relaunches it at once,
checking neither `ConfluxEnabled` nor `DisableNetwork`. The first hop's connect is
refused (connection.c:2200), `connection_or_connect_failed` calls
`note_or_connect_failed`, and `should_connect_to_relay` then refuses that guard for
`OR_CONNECT_FAILURE_LIFETIME`, 60 seconds, with nothing that clears it sooner. So the
runtime is `up` on a fresh listener and carries nothing for over a minute. Whether a
set is mid-link at the moment of the reopen is timing, which is why the probe passed
twice and failed once.

Turning conflux off during the reopen does not help: a leg that opens with conflux off
is closed (`conflux_circuit_has_opened`), and that close takes the same relaunch path.
tor now starts with `ConfluxEnabled 0` and nothing sets it back, so `conflux_predict_new`
never builds a set and there is no leg to relaunch. The exit-country pin already set it
to 0 for its own reason (BUG-014, caution 17); clearing the pin no longer hands it back to
`auto`. The probe now fails on the BUG line itself, and `test/js/tor_suspension.test.js`
fails if the launch configuration drops the setting or anything sets it to `auto`.

**Why it is partial.** It removes the one path found to connect under `DisableNetwork`,
not the class: any other relaunch tor makes from a close handler would hit the same
refusal, and `cycleNetwork` still closes relay connections the only way that closes the
dead listener. Conflux is a throughput feature, so a busy page may load a little slower.
As with attempt 11, nothing has run this on an iOS device.

## Known open gaps

1. **No tier runs the plugin on iOS.** The macOS half of this gap is closed by
   attempt 10; the iOS half is untouched and is the one that matters.
   `integration_test/tor_test.dart` runs the same source on macOS. Every run before
   2026-09-15 17:28 UTC was cancelled by the next push (`cancel-in-progress`) or died
   at `Build macOS` before reaching the step; the first run to get that far takes over
   an hour. Every failure in this file was first observed on a user's device, hours
   ahead of CI. `tool/swift_typecheck` (attempt 4) covers only whether the file
   compiles; nothing executes a line of it.
   Attempt 5 also found the tier would have let this failure through quietly on any run
   without `WEBSPACE_TOR_NETWORK=1`: a `controlChannel` error was folded into "Tor did
   not reach the network here" and marked as a skip. It now fails on every run, since
   nothing about reaching tor's own control port depends on the network.
   And it could not have reported in time even uncancelled: the scenario rode an
   alphabetical `for` loop over the tier's 19 files, where `tor_test.dart` sorts 17th,
   inside a step capped at 45 minutes that already spends ~36 on the others, while its
   own two scenarios can take 13. It now runs first, in a step of its own, so a Tor
   regression reports minutes after the macOS build rather than after the whole tier.
2. **The policy is in the wrong layer.** Retry budgets, the orphan-halt schedule, the exit
   wait and the generation guard are all decisions, and they sit in Swift. Moving them
   into `TorEngine` — with the plugin reduced to `startThread` / `attachOnce` /
   `haltOrphan` / `isThreadFinished` — would put every one of them under the Dart tier
   that already runs 3187 tests, and would let a fake inject the cases that actually
   happen: a slow port, a refused cookie, a tor that will not exit.
3. **A session that loses tor cannot get it back.** Attempt 9 stops the app from
   spending the one launch, but nothing recovers one that is genuinely spent: a
   bridge edit, a `SIGNAL HALT` that lands, or a tor that exits on its own all
   end the feature until the app is restarted. The only real fix is out of
   process — tor in an XPC service or an extension — which iOS makes expensive
   and macOS does not make free. Until 2026-09-29 this and gap 1 held Tor behind
   developer mode (TOR-007); it has since graduated with both still open, so this
   now reaches every iOS and macOS user who picks Tor, and what stands between
   them and a silent dead feature is the named failure TOR-015 shows.
4. **Fault injection barely exists.** The macOS tier exercises the happy path, a
   restart and, since attempt 11, a process whose sockets were defuncted; nothing
   simulates a control port that opens late, which is the mechanism of attempt 2, or a
   process frozen rather than merely cut off.
