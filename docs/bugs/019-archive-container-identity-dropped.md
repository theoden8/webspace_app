# BUG-019 — An archived site's webview binds a container named after its cleartext id

Status: **closed.** Every webview that runs as a site binds through
`WebViewFactory.storeBinding(SitePosture)`, and a `SitePosture` cannot be built
without the opaque id: it is a required field of the posture's container group,
filled only by `WebViewModel.sitePosture` (attempt 4). The close still sweeps
any `ws-<siteId>` an earlier build left behind.

**Spec:** [archive](../../openspec/specs/archive/spec.md) ARCH-006, ARCH-007
(the delta in `openspec/changes/archive-nested-container/`),
[nested-url-blocking](../../openspec/specs/nested-url-blocking/spec.md) NESTED-010
**Tests:** `test/site_posture_test.dart` (an archive-tier posture carries the
opaque id; only the resolver builds a posture),
`test/js/archive_container_identity.test.js` (the close-time sweep),
`test/js/site_info_container_source.test.js` (the binding and the info sheet
read the same posture)
**Related:** [BUG-025](025-nested-posture-drift.md), the class this is one
instance of
**Security review:** [2026-09-10](../security/2026-09-10-review.md) SEC-002, SEC-014

## Symptom

On Android, a link an archived site opens lands in a nested screen that is
signed out of the site. On disk, a profile directory named `ws-<siteId>`, the
archived site's cleartext id, appears and is still there after the archive is
closed, until the next cold start sweeps it as an orphan. While it exists, a
directory listing says which site the archive holds.

## Root mechanism

An archive-tier site's identity on the device is `archiveContainerId`, an HMAC
of the archive key and the site id (ARCH-007). It is runtime state on the
model, not a per-site setting, so it is not in `toJson`, and the checklist for
threading per-site fields into nested webviews never reached it. Any webview
config that carries the site's `siteId` without the opaque id falls back to
`ws-<siteId>`. Off Android that fallback is harmless for an archive site,
because incognito binds no container there. On Android it binds a persistent
named profile.

**Invariant:** a webview that runs as an archive-tier site binds by
`archiveContainerId`, whichever surface builds it.

## Fix attempts

1. **2026-09-10, db47ddd (#593), SEC-002.** Android bound incognito and
   archive-tier sites to the persistent default profile. *What:*
   `siteOwnsContainerProfile` binds a named profile on Android even under
   incognito, `ws-<archiveContainerId>` for archive tier. *Why:* the default
   profile is shared by every unbound site and outlives the archive.
   *Why partial:* it covered the site's own webview. The nested screen's
   config had no `archiveContainerId`, so from then on it bound `ws-<siteId>`,
   a persistent profile named after the archived site.

2. **2026-09-10, db47ddd (#593), SEC-014.** Nested launches dropped per-site
   fields. *What:* every nested launch passes the whole chain through the
   `effective*` getters. The archive nested-container finding was folded in,
   with the advice not to thread `archiveContainerId` because "an incognito
   nested config binds no container", and a suggested defence-in-depth
   delete at close. *Why partial:* that premise was false on Android after
   attempt 1, which landed in the same PR. The delete was not added. The
   posture gate recorded `archiveContainerId` as a `KNOWN_GAP`.

3. **2026-09-26, #634.** *What:* `archiveContainerId` joins the nested chain
   (`LaunchUrlFunc`, both `launchUrlFunc` call sites, `launchUrl`,
   `_launchNestedForModel`, `InAppWebViewScreen` and its `WebViewConfig`) and
   moves from `KNOWN_GAP` to `POSTURE`. `_closeArchive` deletes `ws-<siteId>`
   for the archive's sites unless an app-tier site holds the same id. *Why:*
   the nested screen is a webview that runs as the site, so it binds as the
   site. The sweep covers profiles left by earlier builds and by any path
   that repeats the mistake. *Why partial:* see below.

4. **2026-10-06, #680,
   BUG-025 attempt 6.** *What:* the per-site chain became one `SitePosture`
   value, required by `WebViewConfig`, `InAppWebViewScreen` and `launchUrl`,
   with `archiveContainerId` in its container group; `storeBinding` and the
   router identity read the binding from it. *Why:* gap 1 below said nothing
   forced a future `WebViewConfig` to carry the id; now one cannot be built
   without it, and nothing but `WebViewModel.sitePosture` fills it in. *Why
   it closes the class:* the id is no longer a field a surface threads, so no
   surface can leave it out.

## Known open gaps

1. ~~A new surface that builds a `WebViewConfig` for a site is gated only if
   it goes through the nested chain.~~ Closed by attempt 4.
2. The close-time sweep skips an id an app-tier site also holds. A leaked
   `ws-<siteId>` for such a site is indistinguishable from that site's own
   container and is left alone. Only an older build can have left one.
