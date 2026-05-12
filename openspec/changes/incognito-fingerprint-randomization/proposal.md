## Why

Issue #327: when both Tracking Protection and Incognito are enabled for a site, the anti-fingerprinting shim still seeds its PRNG with `siteId` alone, so the fingerprint is identical across launches. That's the documented and desired posture for non-incognito sites (so a session-stable identity reduces re-identification jitter that itself becomes a tell), but for an incognito site the user has already declared "treat me as a fresh visitor every launch". Returning the same Canvas hash, WebGL strings, screen dims, hardware concurrency, audio buffer noise, etc. across cold restarts breaks that contract — the per-site fingerprint is itself a stable cross-launch identifier.

## What Changes

- Mix a process-lifetime random nonce into the fingerprint seed when `incognito && trackingProtectionEnabled`. Non-incognito sites are unchanged (siteId-only seed → stable per-site fingerprint, current ETP-004 behavior).
- New `lib/services/launch_nonce.dart`: lazy `LaunchNonce.value` generated once per process via `Random.secure`, stable for the lifetime of the process so multiple reads within a session see the same fingerprint. Cold restart → fresh nonce → fresh fingerprint.
- New pure helper `computeAntiFingerprintingSeed({siteId, incognito, launchNonce})` in `anti_fingerprinting_shim.dart` so the seed-derivation rule is unit-testable in isolation.
- `WebViewFactory.createWebView` swaps `siteId!` for `computeAntiFingerprintingSeed(...)` at the existing shim-injection site.
- Spec: amend ETP-004 to carve out the incognito case; add ETP-019 covering the launch-nonce contract.

## Scope

- Behaviour change is gated on `incognito && trackingProtectionEnabled`. Both off → no change. TP only → no change. Incognito only → shim isn't injected anyway (gated upstream).
- No new dependencies, no native platform code, no plugin changes.
- The nonce is per-process, not per-tab. All incognito sites in a launch share the same nonce so two incognito tabs of the same site see the same fingerprint within the session (no flicker on iframe re-injection).

## Non-Goals

- No real-engine fingerprint proofing — the existing jsdom test tier is unchanged. We only assert the seed-derivation logic; the downstream shim-text changes are already covered by ETP-004's "different seeds → different shim" scenario.
- No persistence of the nonce. Backgrounding the app is NOT a launch boundary; only process restart regenerates it. (Matches the user-mental-model of "I closed the app and reopened it".)
- No cross-platform divergence: `Random.secure` is available on every platform we ship.
