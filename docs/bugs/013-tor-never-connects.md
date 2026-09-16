# BUG-013: Tor never reaches `up`, and the runtime is unusable afterwards

**Status:** open (two mechanisms fixed, neither observed fixed on a device yet; the
class stays open until a tier actually runs the plugin — see open gaps)
**Platform:** iOS (the plugin also builds for macOS, where the integration tier runs it).
**Spec:** [tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md)
TOR-018 (the bootstrap says what it is doing), TOR-019 (one control connection, read
before subscribing), TOR-020 (one tor per process; a stop asks it to exit).
**Tests:** `integration_test/tor_test.dart` (the only tier that runs the plugin, macOS
only), `test/js/tor_bootstrap_observability.test.js` (structural) and
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
**Why it was partial:** the ceiling is upstream and stays. Tor is now unavailable for
the rest of the session after any genuine teardown — a bootstrap that really cannot
finish still leaves a tor running and retrying, and a bridge configuration edited
mid-session still needs an app restart to apply. Neither is fixed here; both are now
said out loud instead of hanging. `integration_test/tor_test.dart:252` ("a restart
inside the handshake window still comes back") asserts the behaviour this attempt
removes and is rewritten to assert the refusal instead.


## Known open gaps

1. **No tier runs the plugin on iOS, and the macOS tier has never returned a verdict.**
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
   and macOS does not make free.
4. **Fault injection does not exist at any layer.** Even the macOS tier only exercises the
   happy path plus a restart; nothing simulates a control port that opens late, which is
   the mechanism of attempt 2.
