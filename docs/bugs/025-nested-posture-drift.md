# BUG-025 — A nested webview runs under a posture other than its site's

Status: **closed.** Every webview that runs as a site, the nested screen and
the popup included, is built from one `SitePosture` that `WebViewModel.sitePosture`
resolves. Its fields are required with no default and nothing else constructs
one, so a surface can neither drop a field nor re-derive one differently. The
one deliberate nested difference is `SitePosture.forNested()`.

**Spec:** [nested-url-blocking](../../openspec/specs/nested-url-blocking/spec.md) NESTED-010,
[tracking-protection](../../openspec/specs/tracking-protection/spec.md) ETP-002, ETP-016, ETP-018,
[per-site-location](../../openspec/specs/per-site-location/spec.md) LOC-007, LOC-010,
[archive](../../openspec/specs/archive/spec.md) ARCH-006,
[localcdn](../../openspec/specs/localcdn/spec.md) LCDN-007
**Tests:** `test/site_posture_test.dart` (the Tracking Protection x tier
matrix, nested equals root but for the capture grants, the timezone case below,
and that only the resolver builds a posture), `test/js/effective_getter_boundary.test.js`
(the resolver reads every overridden field through its getter)
**Security review:** [2026-09-10](../security/2026-09-10-review.md) SEC-007, SEC-014
**Related:** [BUG-019](019-archive-container-identity-dropped.md), the
archive container id as one instance of this class

## Symptom

A link opened from a site lands in a nested screen that is less private than
the site: a spoof, a blocker or an override the site applies is missing or
different one hop out. Nothing reports it. The latest instance: a site with
Tracking Protection on and picked coordinates spoofed its timezone, and the
page a link opened from it reported the device's real one.

## Root mechanism

The nested screen had no model, so the site's posture reached it as about 45
loose values respelled at each hop: `LaunchUrlFunc`, its two call sites in
`getWebView`, `_launchNestedForModel`, `launchUrl`, the `InAppWebViewScreen`
constructor and fields, and the nested `WebViewConfig`. 32 of `launchUrl`'s
parameters and most of `WebViewConfig`'s had defaults, so a forgotten field
compiled and failed open. Worse than dropping a field, the nested screen
re-derived what the root had already resolved (the umbrella's forcing, the
WebRTC floor, the timezone), from raw values, with its own expressions, and
those copies drifted from the root's.

**Invariant:** a webview that runs as a site applies exactly the posture the
site resolves, whichever surface builds it.

## Fix attempts

1. **2026-07-17, 50f6595e (#487).** *What:* `test/js/nested_webview_posture_parity.test.js`
   classified every `WebViewConfig` field as posture, plumbing or a known gap,
   and required each posture field to appear as an argument of the nested
   `WebViewConfig` and of `launchUrl`. *Why:* the CLAUDE.md rule was enforced
   by review alone. *Why partial:* it checked that a name was passed, not what
   was passed, so a nested value computed differently from the root's passed;
   `archiveContainerId` sat in the known gaps.

2. **2026-08-20, d8d219e6 (#542).** *What:* third-party cookies joined the
   umbrella (ETP-024), with `tracking_protection_umbrella_funnel.test.js`
   requiring each carrier to spell a forced setting as its forcing expression.
   *Why:* the umbrella is only as strong as the weakest path to a webview.
   *Why partial:* the nested screen kept its own copy of every forcing rule,
   checked per listed field; a forced value the gate did not list (the
   timezone) could still differ.

3. **2026-08-28, 04cc5718 (#562).** *What:* `blockedCookies`, the camera and
   microphone modes and sources, and `protectedContentAllowed` joined the
   nested chain; `test/nested_webview_field_parity_test.dart` read the typedef
   and required each parameter at every hop. LocalCDN regained its archive
   override at the root. *Why:* those fields were in `toJson` and the root's
   config but nowhere one hop out. *Why partial:* the chain still had
   fail-open defaults, and the LocalCDN fix stopped at the root: the nested
   screen kept `localCdnEnabled || trackingProtectionEnabled`, true for an
   archive-tier site under the umbrella.

4. **2026-09-10, db47dddf (#593), SEC-014 and SEC-007.** *What:* share,
   deep-link and URL-bar launches, each with a hand-copied argument list, went
   through one `_launchNestedForModel` passing the `effective*` getters; a
   nested screen asks again for a `real` capture grant (`nestedSeedMode`).
   *Why:* those launches dropped camera, microphone, redirect and incognito
   settings. *Why partial:* it added a third full spelling of the chain, and
   left the archive container id out (BUG-019).

5. **2026-09-26, 1aab8389 (#634).** *What:* `archiveContainerId` joined the
   chain (BUG-019 attempt 3). *Why partial:* one more field threaded by hand
   through seven places; the next field would need the same.

6. **2026-10-06, #680.**
   *What:* `SitePosture`, one immutable value in six groups (container,
   blocking, fingerprint, location, media, page), every field required, built
   only by `WebViewModel.sitePosture`, where the umbrella's forcing and the
   archive overrides are applied once. `LaunchUrlFunc`, `launchUrl`,
   `InAppWebViewScreen`, `WebViewConfig` and `storeBinding` take it whole; the
   popup shares the site's native settings builder. This instance: the nested
   config passed `spoofTimezone: null` under the umbrella with coordinates set,
   following ETP-018's old text that the factory would resolve the zone from
   the coordinates; since the zone is resolved at settings save and stored in
   `spoofTimezone`, the factory only reads the stored zone, so the nested page
   had none. LocalCDN's nested disagreement went with the field: per-site
   LocalCDN turned out to be read by no native path, so it is no longer
   threaded at all (open gap 1). The popup had missed the umbrella's Android
   settings (`X-Requested-With`, attribution reporting, media integrity).
   *Why it closes the class:* a surface cannot be built without a posture, a
   posture cannot be built without every field, and `site_posture_test` fails
   if anything but the resolver and `forNested` constructs one.

## Known open gaps

1. **Closed 2026-10-06.** Per-site LocalCDN was stored, shown and forced by
   the umbrella, but the native interceptor served the app-wide cache to
   every site and nothing told it a site opted out. It now rides the posture
   (`blocking.localCdn`, from `effectiveLocalCdnEnabled`) into
   `attachToWebViews`, which keeps it per site beside the DNS level and moves
   an attached interceptor's `@Volatile localCdnEnabled`. Gated by
   `LocalCdnPerSiteTest.kt` (JVM) and `integration_test/localcdn_per_site_test.dart`
   (emulator, cache vs network at the effect level).
2. The site's own webview reads a few values live from the model instead of
   its posture, because they change in place (a move into or out of an
   archive, a capture popup answered): the external-link mode, blocked
   cookies, capture modes, and `setController`'s four settings. They read the
   same `effective*` getters the resolver does.
