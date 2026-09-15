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


## Known open gaps

1. **No tier runs the plugin on iOS.** `integration_test/tor_test.dart` runs the same
   source on macOS and has never executed in CI (it landed with the branch that added it).
   Every failure in this file was first observed on a user's device. `tool/swift_typecheck`
   (attempt 4) covers only whether the file compiles; nothing executes a line of it.
2. **The policy is in the wrong layer.** Retry budgets, the orphan-halt schedule, the exit
   wait and the generation guard are all decisions, and they sit in Swift. Moving them
   into `TorEngine` — with the plugin reduced to `startThread` / `attachOnce` /
   `haltOrphan` / `isThreadFinished` — would put every one of them under the Dart tier
   that already runs 3187 tests, and would let a fake inject the cases that actually
   happen: a slow port, a refused cookie, a tor that will not exit.
3. **Fault injection does not exist at any layer.** Even the macOS tier only exercises the
   happy path plus a restart; nothing simulates a control port that opens late, which is
   the mechanism of attempt 2.
