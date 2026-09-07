# Nested URL Blocking

## ADDED Requirements

### Requirement: NESTED-011 - A Declined Window Request Is Not Reissued By The Platform

When `onCreateWindow` returns `false`, the navigation MUST NOT happen. This is
the contract NESTED-004 (script-initiated cross-domain blocking), NESTED-005
(captcha allowance) and NESTED-008 (`target="_blank"` routing) all rest on:
each of them expresses its decision solely through that return value.

The plugin does not honour it uniformly. On iOS and macOS the `false` branch
runs `defaultBehaviour`, which loads `navigationAction.request` into the
**parent** webview
(`InAppWebView.swift:2762-2766` in the pinned fork); on Android the
same branch only discards the pending window message. The host cannot observe
the difference: the handler returns, the block is logged, and iOS navigates
anyway.

The fork MUST bring iOS and macOS to Android's behaviour, so that declining a
window request is a decision rather than a suggestion on every shipped
platform.

Where the host wants the URL loaded in the current webview after declining a
window (NESTED-008's same-domain path, EXT-003's resolved intent), it MUST do
that itself with an explicit `loadUrl`. A platform that also loads the original
request produces two navigations, the second of which skips every rewrite the
first one applied.

#### Scenario: Script-initiated cross-domain popup on iOS

- **GIVEN** a site whose script calls `window.open('https://other.example')`
  with no user gesture
- **AND** the per-site auto-redirect block is on (NESTED-004)
- **WHEN** `onCreateWindow` returns `false`
- **THEN** no navigation occurs in the parent webview
- **AND** the site stays on its current page, as it does on Android

#### Scenario: A declined window is not loaded twice

- **GIVEN** a `target="_blank"` link that NESTED-008 routes by calling
  `loadUrl` with a ClearURLs-stripped URL and then returning `false`
- **WHEN** the platform processes the return value
- **THEN** exactly one navigation occurs, to the stripped URL
- **AND** the original, unstripped request is not loaded on top of it

#### Scenario: Parity is asserted, not assumed

- **GIVEN** the fork's `onCreateWindow` decline path on Android, iOS and macOS
- **WHEN** the fork is rebased or retagged
- **THEN** a test asserts that none of the three platforms navigates the parent
  on a `false` return, so a reintroduction fails the build rather than
  reappearing in the field

### Requirement: NESTED-012 - Cancel-And-Reissue Loses Navigation Provenance

`useShouldOverrideUrlLoading` is set unconditionally
([lib/services/webview.dart:3531](../../../../../lib/services/webview.dart)),
and the Android client returns `true` for every main-frame navigation even when
the Dart side answered ALLOW, reissuing it as a fresh programmatic
`webView.loadUrl(url, headers)`.

A reissued navigation is not the navigation the user made. It arrives at the
destination with no `Referer`, no `window.opener`, and `Sec-Fetch-Site: none`
instead of `cross-site`. Two of those three are privacy wins we keep. The third
is not: a destination that treats `Sec-Fetch-Site: none` as "the user typed this
in the address bar" will extend trust to what was actually a cross-site link,
and container isolation attaches that site's cookies because it keys on
`siteId`, not on how the navigation arrived.

This is accepted behaviour, not a defect to fix here. iOS already takes the same
shape deliberately under IOS-UL-001. The requirement is that it be **stated**:
anyone reasoning about what a WebSpace site sees on an inbound navigation MUST
be able to find out that provenance headers are stripped without reading the
fork.

#### Scenario: A cross-site link arrives looking direct

- **GIVEN** a link from a hostile page to a site the user has in WebSpace
- **WHEN** the navigation is allowed and reissued by the Android client
- **THEN** the destination receives `Sec-Fetch-Site: none` and no `Referer`
- **AND** this spec says so, so the destination's trust decision is a known
  property of the app rather than a surprise

### Requirement: NESTED-013 - Top-Document Steering Requires A Trustworthy Main-Frame Signal

`shouldOverrideUrlLoading` fires for subframe navigations as well as main-frame
ones, and several actions below the main-frame gate steer the **top** document:
the ClearURLs rewrite and the ABP `$removeparam` rewrite both respond to a match
by calling `loadUrl` on the top frame and cancelling the original navigation, and
the cross-domain path routes the navigation into a nested `InAppWebViewScreen`.

Those actions are correct for a main-frame navigation and are a redress attack
for a subframe one: an embedded cross-origin iframe gets to decide where the
whole page goes. The existing gate says so already, requiring that "a
cross-origin subframe navigation must never be able to steer the top document".

The gate is only as good as its input, and its input is not uniform. Android
reports `isForMainFrame` correctly. Linux cannot: WPE WebKit exposes no
main-frame flag on `WebKitNavigationAction`, so the plugin infers it from
`webkit_navigation_action_get_frame_name()` being empty, which is the *target*
frame name and so is also empty for every unnamed iframe. The inference defaults
to main frame, and the app then reads `isForMainFrame ?? true`, so an unreliable
signal and a missing signal both resolve to the permissive answer.

That much is already recorded, in this spec's platform-gesture section and in
[PR #356](https://github.com/theoden8/webspace_app/pull/356), which names the
nested-webview consequence and offers per-site `blockAutoRedirects = false` as
the escape hatch. This requirement exists because that hatch covers only the
routing half. It does not disable the rewrites, and the rewrites are the half
that lets a subframe navigate the top document.

Therefore: an action that navigates or replaces the top document MUST NOT run on
a main-frame signal the platform cannot vouch for. Where the signal is absent or
known-unreliable, the navigation is allowed to proceed unmodified rather than
rewritten or rerouted. Losing a stripped tracking parameter is the acceptable
cost; letting a subframe steer the top document is not.

This requirement is satisfied either by the platform supplying a real signal
(WebKit PR 65415 adds `webkit_navigation_action_is_for_main_frame()` for
WPE/GTK, after which the fork can drop the inference) or by the app treating the
inferred signal as untrustworthy. The app-side half MUST NOT wait for the
platform half.

#### Scenario: A tracking parameter inside an iframe URL

- **GIVEN** a page on Linux embedding a cross-origin iframe whose URL carries a
  parameter ClearURLs strips
- **WHEN** the iframe navigates and `shouldOverrideUrlLoading` fires
- **THEN** the top document does not navigate to the iframe's URL
- **AND** the iframe is allowed to load, stripped or not

#### Scenario: An embedded sign-in iframe

- **GIVEN** a cross-domain SSO or captcha iframe on a platform with no reliable
  main-frame signal
- **WHEN** the navigation is evaluated
- **THEN** it loads in place
- **AND** it is not routed into a nested `InAppWebViewScreen`

#### Scenario: The signal becomes trustworthy

- **GIVEN** a platform that reports main-frame status from the engine rather than
  by inference
- **WHEN** a genuine main-frame navigation carries a tracking parameter
- **THEN** the rewrite runs as it does on Android, with no capability lost
