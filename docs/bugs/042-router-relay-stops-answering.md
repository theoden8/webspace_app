# BUG-042: Every site fails on a router relay that stopped answering

Status: open

**Spec:** [proxy](../../openspec/specs/proxy/spec.md) PROXY-013 (the
listener outlives a failed accept), PROXY-032 (a relay that stops answering
is bound again)
**Tests:** [ProxyRelayRouterTest.kt](../../android/app/src/test/kotlin/org/codeberg/theoden8/webspace/proxy/ProxyRelayRouterTest.kt)
(`aFailedAcceptDoesNotEndTheRelay`, `aListenerNobodyAcceptsOnDoesNotServe`,
`theAcceptLoopSaysWhenItEnds`), [test/proxy_router_service_test.dart](../../test/proxy_router_service_test.dart)
("a relay that stops answering (PROXY-032)")

## Symptom

On Android in router mode, every site stops loading at once and keeps
failing until the app is force-stopped: each main-frame load ends in
`ERR_PROXY_CONNECTION_FAILED`, which the WebView reports as
`PROXY_AUTHENTICATION`. Sites with no proxy fail too, because the one
process-wide rule sends every site's traffic to the relay.

## Root mechanism / invariant

`ProxyController` carries one rule for the process, and router mode points it
at the loopback relay for the whole run (PROXY-013). The Dart side's idea of
whether the router runs (`ProxyRouterService.isActive`) is its own
bookkeeping and was never checked against the relay. So when the relay
stops answering, whatever the cause, nothing notices: no site shows the
block, nothing binds the relay again, and every load fails until the process
dies. The invariant is that the rule names a listener that answers; each fix
below covers one way it stops answering.

## Fix attempts

1. **2026-10-27, `671c22ca` (#801).** The accept loop retries a failed
   `accept()` with a backoff instead of ending on it. *Why:* a device out of
   descriptors made one accept fail, the loop ended, and the rule kept
   pointing every site at a port nobody served. *Why partial:* it covers the
   one cause it names, a failed accept, inside the loop. A listener closed
   from outside the loop, an accept thread that stops making progress, or a
   rule moved off the relay still fails every site, and silently: the loop's
   exit on a closed socket logged nothing.

2. **2026-10-30, this branch.** A main-frame `ERR_PROXY_CONNECTION_FAILED`
   under the router asks the relay whether it serves (a request answered,
   not just an open socket). One that does not is stopped and bound again
   with its routes and the rule, and the load is issued again; one that
   answers gets the rule pointed at it again, without a reload. A relay that
   cannot be bound again takes the router down for the run, so proxied sites
   show the block. The accept loop logs its end, and the Dart side logs
   refused relay calls. *Why:* a user's log showed the relay's last accepted
   connection at 22:43:37, then `ERR_PROXY_CONNECTION_FAILED` for every site
   from 22:45:59, with no stop, no failed accept and no restart logged, while
   the app was in the background under memory pressure. *Why partial:* it
   recovers from the symptom without naming the cause, which that log could
   not show. A rule moved off a relay that still answers is pointed back,
   but the failed load is not issued again.

## Known open gaps

- The cause of the 2026-10-30 instance is unknown. One lead: the background
  wake's worker engine (`WorkerFlutterEngine`) has its own relay plugin, and
  its Dart startup can point the process-wide rule at that relay, which
  stops with the engine. The developer-mode background log records when a
  wake starts its own engine ("starting one for the wake").
- Recovery is driven by a main-frame load failing. A site that only makes
  subresource requests (a page already loaded) waits for its next
  navigation or for another site's failed load.
