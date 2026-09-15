# BUG-013: Tor never reaches `up`, and the runtime is unusable afterwards

**Status:** open (two mechanisms fixed, neither observed fixed on a device yet; the
class stays open until a tier actually runs the plugin — see open gaps)
**Platform:** iOS (the plugin also builds for macOS, where the integration tier runs it).
**Spec:** [tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md)
TOR-018 (the bootstrap says what it is doing), TOR-019 (one control connection, read
before subscribing), TOR-020 (one tor per process; a stop asks it to exit).
**Tests:** `integration_test/tor_test.dart` (the only tier that runs the plugin, macOS
only) and `test/js/tor_bootstrap_observability.test.js` (structural). Every other Tor
test drives a fake `TorRuntime`.

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

## Known open gaps

1. **No tier runs the plugin on iOS.** `integration_test/tor_test.dart` runs the same
   source on macOS and has never executed in CI (it landed with the branch that added it).
   Every failure in this file was first observed on a user's device.
2. **The policy is in the wrong layer.** Retry budgets, the orphan-halt schedule, the exit
   wait and the generation guard are all decisions, and they sit in Swift. Moving them
   into `TorEngine` — with the plugin reduced to `startThread` / `attachOnce` /
   `haltOrphan` / `isThreadFinished` — would put every one of them under the Dart tier
   that already runs 3187 tests, and would let a fake inject the cases that actually
   happen: a slow port, a refused cookie, a tor that will not exit.
3. **Fault injection does not exist at any layer.** Even the macOS tier only exercises the
   happy path plus a restart; nothing simulates a control port that opens late, which is
   the mechanism of attempt 2.
