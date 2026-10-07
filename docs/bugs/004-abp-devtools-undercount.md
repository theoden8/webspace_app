# BUG-004 — ABP block counts undercounted in DevTools

Status: open

## Symptom

The DevTools ABP tab shows far fewer blocks than actually happen — often
zero — while the per-site DNS tab (`DnsStats.blockedByAbp`) and the stats
banner show engine-attributed blocks piling up. The user reads "engine
active, 0 blocked" and concludes the content blocker is broken.

## Root mechanism / invariant

The ABP tab's numbers come from `ContentBlockerService`'s decision
recorder (`_recordEngineDecision`), but the engine is consulted through
several independent paths, and each new path defaults to *not* recording.
Any consult path added without touching the recorder silently disappears
from the tab. The invariant: **every path that obtains a network-block
verdict from the engine — Dart `shouldBlock` wrappers or the Android
native JNI engine — must fold that verdict into the DevTools counters.**
Spec: CB-012 in
[openspec/specs/content-blocker/spec.md](../../openspec/specs/content-blocker/spec.md).

Consult paths as of this writing:

- `isBlocked` — main-doc navigations (`shouldOverrideUrlLoading`,
  `onLoadStart`), iOS/macOS JS-bridge `blockCheck`.
- `isHostBlocked` — iOS/macOS PerformanceObserver per-host attribution
  (`blockResourceLoadedBatch`), the dominant stats path on those
  platforms.
- Android native JNI engine (`FastSubresourceInterceptor`) — decisions
  never enter Dart; only drained block events
  (`WebInterceptNative._drainBlockEvents`) reach the Dart side.

## Fix attempts

1. **2026-06-25 — PR #446** (`3fcc1b5`). Reordered the iOS `blockCheck`
   handler to consult the ABP engine *before* the DNS early-return —
   with a DNS blocklist active, hosts on both lists returned from the
   DNS branch first and the engine was never asked, so the ABP tab read
   zero blocks. *Why partial*: only covered the `blockCheck` path. The
   `isHostBlocked` attribution path recorded nothing at all, Android
   native blocks never reached the recorder, and the tab's
   blocked/allowed chips were computed over the rolling 200-sample ring,
   so they decayed as samples rolled off (while "consulted" was
   cumulative — mismatched semantics on one row of chips).

2. **2026-07-13 — this branch.** Made blocked/allowed cumulative
   (`engineBlockedSinceTimingOn` / `engineAllowedSinceTimingOn`, reset
   with the timing toggle like `engineConsultedSinceTimingOn`); recorded
   `isHostBlocked` decisions (requestType `host`); folded Android native
   `abp`-sourced block events into the counters via
   `recordNativeEngineBlock` (untimed samples, requestType `native`,
   dedup `count` respected); ABP tab now reads the cumulative counters
   and skips untimed samples in avg/max. *Why partial*: native *allowed*
   events aren't attributable (drain events don't say whether the engine
   was consulted), so on Android the Allowed tally remains a Dart-side
   lower bound; if a future platform adds another native consult path it
   must call the recorder itself.

3. **2026-10-07 — #680.** Every Dart path that
   blocks or counts a request now takes one verdict from
   `BlockDecision.decide` (`lib/services/block_decision.dart`), DNS first
   as the CB attribution scenario and Android's native interceptor already
   ordered it, and the page-reachable legacy `blockResourceLoaded` handler,
   which nothing called, is gone. That withdraws attempt 1's forced engine
   consult in `blockCheck`: it was the one path asking the engine about a
   request DNS had already blocked, so its ABP-tab numbers meant something
   different from the batch path's and Android's. *Why partial*: it settles
   what the tab counts (the engine's decisions over what DNS let through,
   on every path) rather than closing the gaps below.

## Known open gaps

- A host both lists block reaches the ABP tab on no path, since the engine
  is not asked about it (CB attribution). With a DNS list on, the tab can
  still read low next to the merged banner count.
- Android native allowed-after-consult decisions are invisible — the
  drain protocol would need an `engineConsulted` flag per event.
- `redirectFor` / `cspFor` / `rewrittenUrl` verdicts are actions, not
  block decisions, and are deliberately not counted; if the tab ever
  grows action chips they need their own accounting.
- iOS hosts blocked at fetch time *and* later re-attributed by the
  PerformanceObserver batch can be counted twice (same as the per-site
  stats path, which has the same shape).
