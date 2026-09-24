# BUG-018 — A UI transition waits on a native call that never answers

Status: **open.** The activation path is gated; other transitions are not.

**Spec:** [navigation](../../openspec/specs/navigation/spec.md) NAV-010,
[tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md)
TOR-014, TOR-019
**Tests:** `test/js/go_home_commit_funnel.test.js`,
`test/js/activation_awaits_classified.test.js`,
`test/site_teardown_engine_test.dart`, `test/tor_engine_test.dart`
("BUG-018: a clear tor never answers fails closed, once")

## Symptom

A tap on a site, or on "back to webspaces", does nothing. There is no error.
The log shows the transition start and never its end, and every later tap
does the same: each bumps the activation version and then waits at the same
point.

## Root mechanism

A UI state change awaits a native round trip, and the other side can go
silent without failing. A page whose JS thread an earlier pause froze never
answers `evaluateJavascript`. A command Tor.framework writes to a dead control
socket never completes: `sendCommand` registers its reply observer only in the
`dispatch_io_write` completion, and only after a clean write. Nothing closes
the channel when the socket dies, so `isConnected` goes on reporting true.

A Future that never completes is not an error. No `catch` runs, no version
guard fires, and the transition stops halfway with the old state in place.

**Invariant:** nothing a transition awaits may depend on a peer that can go
silent. Such a call is either bounded, or taken off the path with the
fail-closed state it guards published before the caller could have waited.

## Fix attempts

1. **2026-08-24, d1de53b (#551).** Go-home commits `_currentIndex` before the
   teardown, and the teardown runs through `SiteTeardownEngine`: ordered,
   non-fatal, a 2 s budget, version-guarded (NAV-010). *Why:* an iOS page an
   earlier pause had frozen never answered, which left "back to webspaces"
   stranded. *Why partial:* it bounded the teardown steps it knew about and
   gated only the go-home branch. Nothing classified the other awaits on the
   activation path, so the Tor exit-country change, added later with TOR-014,
   went in as an unbounded await.

2. **2026-09-23, Tor exit-country change.** Reported: after a long spell in
   the background, every tap on a site did nothing, and the log stopped after
   `Currently loaded indices: {8}`. The pin in force (`{br}`) belonged to a
   site that memory pressure had evicted without recomputing the pin. The next
   activation, of a site that does not use Tor, computed "no pin" and awaited
   the clear. The RESETCONF went to a control socket that did not survive the
   suspension (tor logged the clock jumping 1357 s), Tor.framework dropped the
   completion, and the method channel never answered. Each later tap re-sent
   the clear, because the engine marked the pin unapplied before awaiting, and
   then waited as well. tor itself was alive throughout, but that proves
   nothing about the socket: the app reads tor's log from its log file, not
   over the control port.

   *What:* `_setCurrentIndex` no longer awaits the pin. The engine publishes
   a hold (not `up`) synchronously, so a Tor-bound site waits behind the
   interstitial until the pin lands and a site that does not use Tor does not
   wait at all. The engine bounds the round trip (30 s) and, on no answer,
   fails closed as a control-channel failure with Retry. A failed change is
   not re-sent on every tap. The native side answers every call exactly once,
   with a 20 s deadline, and bounds each command (8 s). It probes liveness
   with `GETINFO version` (3 s) and re-attaches a fresh control connection
   without `disconnect()`, which would send SIGNAL SHUTDOWN. Memory-pressure
   eviction recomputes the pin when it evicts. *Gate:*
   `activation_awaits_classified` requires every await in `_setCurrentIndex`
   to be listed with the reason it cannot hang, and refuses a Tor call
   outright. *Why partial:* see the gaps below.

## Known open gaps

1. Only `_setCurrentIndex` is gated. Other transitions still await native
   work that nothing classifies. One example: a settings save goes through
   `_saveWebViewModels`, `_syncTorHolders` and `syncHolders`, and with
   bridges configured that reaches `startTransport`.
2. The awaits the gate lists are classified by argument, not measured.
   `resumeWebView`, `clearWebViewCache` and `ensureContainer` are in-process,
   main-thread calls that are believed always to answer.
3. The plugin's other control commands are not bounded the same way.
   `rebuildCircuits` fires and forgets, and the attach-time reads in
   `observeLocked` are bounded only by the bootstrap deadline.
4. Re-attaching is lazy: a dead control socket is found when a pin change
   needs it, and nothing checks it on foregrounding.
5. Not reproduced on a device. The mechanism is read from Tor.framework
   v409.11.2's source and matched against the reported log; no tier here
   reclaims a socket under a suspended app.
