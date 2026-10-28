# BUG-040 — A `real` capture grant reaches a page the user did not answer for

Status: **open.** Every surface that runs another page under a site now takes a
grant store of its own seeded from the site's nested posture, but each surface
builds it itself, so the next surface can hand its page the site's persisted
store again.

**Spec:** [web-screen-sharing](../../openspec/specs/web-screen-sharing/spec.md) SHARE-014,
SHARE-017; [web-camera-access](../../openspec/specs/web-camera-access/spec.md) CAM-005;
[web-microphone-access](../../openspec/specs/web-microphone-access/spec.md) MIC-005;
link-intent-routing LIR-034 (`openspec/changes/web-search/specs/link-intent-routing/spec.md`)
**Tests:** `test/js/page_bridge_authority.test.js` (SHARE-014 for the popup,
LIR-034 for the foreign tab), `test/site_posture_test.dart` (`forNested` resets
`real`)
**Security reviews:** [2026-09-10](../security/2026-09-10-review.md) SEC-007, A-4;
[2026-10-28](../security/2026-10-28-review.md) SEC-031, SEC-032

## Symptom

The user allows a site a real device or the real screen, and a page that is
not that site's own (a page a link opened, a popup the site's page opened, a
tab running another domain under the site) gets the same grant without being
asked, or an Allow the user gave that page is saved onto the site.

## Root mechanism

A grant is consent the user gave one prompt that named one origin. The site's
webview answers capture from `PersistedGrantStore`, which reads and writes the
site's own decision. Any other surface that runs a page as the site is built
from the site's `WebViewConfig`, whose `grants` is that persisted store, so a
surface that does not replace it inherits the site's `real` and saves its own
answers onto the site.

## Fix attempts

1. **2026-09 (e3b1c60, SEC-007).** The nested `InAppWebViewScreen` builds an
   `InMemoryGrantStore` from `SitePosture.forNested()`, which resets every
   `real` to `ask`. *Why:* a link one hop out is not the page the user
   answered for. *Why partial:* the rule lives where the nested screen is
   built; popups (`createPopupWebView`) and, later, foreign tabs
   (`getWebView` under LIR-034) take the site's config whole. A-4 in the same
   review found the popup half for the camera and left it open.
2. **2026-10-28 (#835, SEC-031, SEC-032).** Real screen sharing runs over the
   app's own bridge, so a popup's page could start a share under the site's
   grant with only the system's prompt in the way. Popups now register their
   handlers with an `InMemoryGrantStore` from the opener's nested posture
   (`PageHandlers.registerPageHandlers` takes the store as its own argument,
   chosen by each surface), and a foreign tab's webview takes the nested
   posture and an in-memory store. A-4 closes with it. *Why partial:* three
   surfaces now build the same store three times.

## Known open gaps

- The rule is restated per surface, held by source gates on the two newest.
  Lifting it to a type would make the persisted store something only the
  site's own webview can obtain (a store the slot model mints for itself, the
  nested form the only thing a config hands on), so a new surface could not
  compile with the site's store.
- A site's own webview answers from the site's persisted grant whatever
  origin its top document has (a redirect target the site keeps, a later
  page). The prompt names the origin that asked first; SHARE-014 and
  CAM-005/MIC-005 accept that within one surface. See SEC-043.
