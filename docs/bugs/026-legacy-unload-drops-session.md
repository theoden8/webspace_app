# BUG-026 — An unload under the legacy engine drops what the site just set

Status: closed

**Spec:** [per-site-cookie-isolation](../../openspec/specs/per-site-cookie-isolation/spec.md)
ISO-002, [webview-pause-lifecycle](../../openspec/specs/webview-pause-lifecycle/spec.md)
PAUSE-007
**Tests:** [test/cookie_isolation_integration_test.dart](../../test/cookie_isolation_integration_test.dart)
("Unload (ISO-002)": every `UnloadReason` against the real jar engine),
[test/site_unload_engine_test.dart](../../test/site_unload_engine_test.dart)
(`SiteUnloadEngine.unload`, and that the page unloads through it)

## Symptom

Under the legacy engine (no per-site containers: Android without
`MULTI_PROFILE`, iOS below 17, macOS below 14), a site signed in after its
activation is signed out again once something else unloads it and another
site activates. A site unloaded by a domain conflict also came back without
its back stack.

## Root mechanism / invariant

The legacy engine keeps every site's cookies in one jar. Each activation
saves the jar for the loaded sites only, then empties it (ISO-003). A site
leaving the loaded set takes its cookies along only if its unload captured
the jar first; otherwise the next activation empties what it set since its own
activation. The invariant: **every unload captures the jar under the legacy
engine, and keeps the back stack unless the site is sent home on purpose.**

## Fix attempts

1. **2026-04-30 — PR #262.** Added `_unloadSiteForOtherReason`, which runs
   the jar capture under the legacy engine, for the proxy-mismatch, loaded-site
   cap and memory-pressure unloads. *Why*: those unloads were new with the
   container-aware policy and would otherwise lose the session. *Why partial*:
   the webspace-switch unload, which only runs under the legacy engine, kept
   disposing without the capture, and the domain-conflict unload kept
   skipping the back-stack capture PAUSE-007 lists for it. A home reset
   (shortcut launch, or a link opening in an always-open-home site) later
   disposed without the capture as well.

2. **2026-10-06 — #680.** Every unload goes through
   `SiteUnloadEngine.unload`: under the legacy engine it captures the jar
   whatever the reason, and `UnloadReason.keepsNavState` (an exhaustive
   switch) decides the back-stack capture. *Why*: one funnel leaves no path to
   forget a step on, and a new reason does not compile until it answers the
   back-stack question. Closes the class.

## Known open gaps

None. Revoking a pinned certificate disposes the host's sites outside the
funnel on purpose: it wipes their sessions so the next load re-handshakes.
