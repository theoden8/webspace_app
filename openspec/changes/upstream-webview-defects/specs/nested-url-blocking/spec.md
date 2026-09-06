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
