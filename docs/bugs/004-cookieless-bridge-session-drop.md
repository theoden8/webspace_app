# BUG-004: Logged-in site drops the session after a bridge-retried fetch

**Status:** open (fallback now scoped to cross-site GET/HEAD; the LinkedIn logout report turned out to be iOS Lockdown Mode, not this bug — see below)
**Platform:** all (shim behavior; only sites with user scripts enabled)
**Spec:** [openspec/specs/user-scripts/spec.md](../../openspec/specs/user-scripts/spec.md) — shim bullet 3
**Tests:** [test/js/user_script_shim.test.js](../../test/js/user_script_shim.test.js) (fetch-fallback scoping group)

## Symptom

A logged-in site suddenly treats the user as logged out — demands login again or
actively terminates the session — shortly after some page fetch fails and is retried.
First confirmed on github.com (site "starts demanding login"); suspected on
linkedin.com (user logged out when opening a messages conversation, iOS — not yet
confirmed with a console log).

## Root mechanism (the invariant behind every instance)

The user-script shim patches `window.fetch` to retry `TypeError` failures through
`__wsFetch`, the Dart-side CORS-bypassing bridge. That bridge issues a bare GET with
**no cookies, no original request headers, and follows redirects**. Any
*session-bound* request retried through it therefore reaches the server as an
unauthenticated client — and comes back as a login page / 401 where the page's code
expected authenticated JSON. Client code commonly reacts to that by clearing the
session or redirecting to login. The invariant every fix must preserve: *a request
that could carry session state must never be reissued through the cookie-less
bridge; only anonymous static-resource fetches may fall back.*

## Fix attempts (chronological)

### Attempt 1 — Scope the fallback to cross-origin URLs
**Date:** pre-2026-06-10 (history shallow; rationale preserved in the shim comment) · **Files:** lib/services/user_script_shim.dart
**What it did:** Added `isCrossOrigin` so only URLs with a different origin than the
page fall back to `__wsFetch`; same-origin TypeErrors rethrow untouched.
**Why:** Same-origin requests always carry the session; retrying one cookie-less made
logged-in github.com demand login.
**Why partial:** Cookies scope to the **registrable domain**, not the origin. A
same-site subdomain request (`www.linkedin.com` → `realtime.www.linkedin.com`, which
LinkedIn messaging uses) is cross-origin yet fully session-bound, so it still fell
back. The fallback also reissued POSTs as GETs and retried explicitly credentialed
(`credentials: 'include'`) requests.

### Attempt 2 — Scope to cross-site, bodyless, non-credentialed requests
**Date:** 2026-07-07 · **Files:** lib/services/user_script_shim.dart
**What it did:** Replaced the origin check with a registrable-domain check
(last-two-labels heuristic; multi-part public suffixes like `co.uk` over-approximate
"same site", which only disables the fallback — the safe direction). Additionally
requires method GET/HEAD and `credentials !== 'include'`.
**Why:** Extends Attempt 1's invariant to every request that can carry session state.
The shim's legitimate fallback consumer — DarkReader fetching page CSS from CDN
domains (`static.licdn.com` from `linkedin.com`) — is cross-site and unaffected.
**Why partial (known gaps):** (a) `XMLHttpRequest` and `EventSource` failures are not
covered (nothing retries them today, but a future "helpful" fallback there would
reopen the bug). (b) Legit cross-site fallbacks still drop request headers (Accept,
Range), which can return subtly wrong resources.

### Postscript — the LinkedIn logout report was NOT this bug

The 2026-07-07 report (LinkedIn logging the user out on opening a messages
conversation, iOS) reproduced with the site's user scripts disabled — i.e. with the
shim, and therefore this fallback, entirely absent. The actual cause was **iOS
Lockdown Mode** (user-confirmed enabled): it strips FileReader, IndexedDB, WebGL,
Web Audio, WASM and JIT from every third-party app's WKWebViews, and LinkedIn's
messaging client fails hard in that environment. The app cannot opt out (requires
the `com.apple.developer.web-browser` entitlement); the user-side fix is Settings >
Privacy & Security > Lockdown Mode > Configure Web Browsing > exclude WebSpace.
`LockdownModeService` + a one-time startup notice now surface this. The Attempt 2
scoping stands on its own merits regardless.

## Known open gaps

- The last-two-labels heuristic misclassifies `foo.co.uk` vs `bar.co.uk` as
  same-site, disabling the fallback there; correct behavior needs a public-suffix
  list, which is not worth shipping in the shim unless a real site regresses.
