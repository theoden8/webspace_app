# User-Agent Identity Consistency Specification

## Status
**Implemented**

## Purpose

Make the JavaScript `navigator` identity fields consistent with the *engine a
per-site User-Agent claims*, so a spoofed UA does not leak the real underlying
WebView engine.

Setting a per-site UA changes only the wire-level `User-Agent` header and (for
desktop UAs) the surfaces `desktop-mode` patches. It does NOT change the
`navigator` fields the JS engine itself populates — `vendor`, `vendorSub`,
`productSub`, `oscpu`, `buildID`, `userAgentData` — nor `navigator.platform` on
mobile. Those come from the real host engine (WebKit on iOS, Blink on Android),
so a UA whose engine disagrees with the host is internally contradictory and
trivially detected by fingerprinting suites (CreepJS, fingerprintjs): e.g. a
Firefox-for-Android (Gecko) UA on an iOS WebView still reports
`navigator.vendor = "Apple Computer, Inc."` (Firefox is `""`) and
`navigator.platform = "iPhone"` (Firefox-Android is `"Linux armv8l"`).

This feature derives the engine from the per-site UA and forces the identity
fields to the values that engine really emits. It complements — and does not
overlap with — `desktop-mode` (which owns platform / userAgentData /
maxTouchPoints for *desktop* UAs, matchMedia pointer/hover, and viewport) and
`tracking-protection` (which owns the anti-fingerprinting noise).

---

## Requirements

### Requirement: UAID-001 - Engine classification from the UA string

The app SHALL classify a UA string into one of `{gecko, webkit, blink,
unknown}` (`inferUaEngine`). Any Apple mobile-browser brand token
(`FxiOS`/`CriOS`/`EdgiOS`/`OPiOS`) classifies as `webkit` regardless of brand,
because iOS mandates WebKit. Real Gecko carries a `Gecko/<digits>` build token
plus `Firefox/`; every WebKit/Blink UA carries only the `(KHTML, like Gecko)`
marker. An empty or unrecognized string is `unknown`, and no shim is injected.

#### Scenario: iOS browsers are WebKit regardless of brand

**Given** a Firefox-for-iOS UA (`... FxiOS/152.0 ... Safari/604.1`)
**When** the engine is inferred
**Then** the engine is `webkit` (not `gecko`)
**And** a Chrome-for-iOS UA (`... CriOS/120 ...`) is also `webkit` (not `blink`)

#### Scenario: Desktop and Android Chrome are Blink; Firefox is Gecko

**Given** `... AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 ...`
**Then** the engine is `blink`
**And** a `... Gecko/20100101 Firefox/152.0` UA is `gecko`
**And** `curl/8.0` is `unknown`

---

### Requirement: UAID-002 - Engine-consistent navigator identity

When a per-site UA is set and classifiable, the app SHALL inject a
`UserScriptInjectionTime.AT_DOCUMENT_START` script (`forMainFrameOnly: false`)
that defines, on `Navigator.prototype`, the identity values the claimed engine
emits:

* `vendor` — Gecko `""`, WebKit `"Apple Computer, Inc."`, Blink `"Google Inc."`
* `vendorSub` — `""` on every engine
* `productSub` — Gecko `"20100101"`, WebKit/Blink `"20030107"`
* `oscpu` (Gecko only) — desktop per-OS token (`"Linux x86_64"`,
  `"Windows NT 10.0; Win64; x64"`, `"Intel Mac OS X 10.15"`), Firefox-Android
  frozen to `"Linux armv8l"` (FF123+)
* `buildID` (Gecko only) — frozen `"20181001000000"` (Firefox 64+ default for
  web content)
* `platform` (mobile only) — Firefox/Chrome-Android `"Linux armv8l"`, iOS
  WebKit `"iPhone"`

Getters are defined on the prototype (never the instance — an own-property on
`navigator` would self-incriminate) and stringify as `[native code]`.

#### Scenario: Gecko-Android identity

**Given** a Firefox-for-Android UA
**When** the page reads navigator
**Then** `navigator.vendor === ""`
**And** `navigator.productSub === "20100101"`
**And** `navigator.oscpu === "Linux armv8l"`
**And** `navigator.buildID === "20181001000000"`
**And** `navigator.platform === "Linux armv8l"`

#### Scenario: WebKit and Blink vendors

**Given** a Firefox-for-iOS UA
**Then** `navigator.vendor === "Apple Computer, Inc."` and
`navigator.productSub === "20030107"`
**And** for a Chrome-for-Android UA, `navigator.vendor === "Google Inc."`

---

### Requirement: UAID-003 - Presence-sensitive fields are absent, not stubbed

The shim SHALL make presence-sensitive fields (`oscpu`, `buildID`,
`userAgentData`) genuinely absent (delete) on engines that lack them — NOT
defined as `undefined` — because consistency checks do `'oscpu' in navigator`.

* `oscpu` / `buildID` — removed for WebKit and Blink UAs (Gecko-only).
* `userAgentData` — removed for Gecko and WebKit UAs (Blink-only); Blink UAs
  keep it. (Desktop UAs already have it removed by `desktop-mode`; the shim
  handles mobile.)

#### Scenario: WebKit UA has no oscpu/buildID

**Given** a Firefox-for-iOS UA
**Then** `'oscpu' in navigator` is `false`
**And** `'buildID' in navigator` is `false`
**And** `'userAgentData' in navigator` is `false`

#### Scenario: Blink UA keeps userAgentData

**Given** a Chrome-for-Android UA
**Then** the shim does NOT remove `navigator.userAgentData`

---

### Requirement: UAID-004 - Scope and non-overlap

The shim SHALL run for every classifiable per-site UA (desktop and mobile) and
SHALL propagate to nested webviews opened via `launchUrl` (it is built inside
`WebViewFactory.createWebView`, which every nested `InAppWebViewScreen` uses,
from the per-site `userAgent`). `navigator.platform` and `userAgentData` are
set here ONLY for mobile UAs; for desktop UAs those remain owned by
`desktop-mode` so the two shims never both define the same property.

#### Scenario: Desktop UA does not double-set platform

**Given** a Firefox desktop UA
**When** the identity shim runs
**Then** it sets `vendor` / `productSub` / `oscpu` / `buildID`
**And** it does NOT define `navigator.platform` (owned by `desktop-mode`)

---

## Files

- `lib/services/user_agent_classifier.dart` — `UaEngine` + `inferUaEngine`
- `lib/services/user_agent_identity_shim.dart` — `buildUserAgentIdentityShim`
- `lib/services/webview.dart` — `UserScript` registration (group
  `ua_identity_shim`) in `WebViewFactory.createWebView`
- `test/user_agent_identity_shim_test.dart` — Dart builder + engine tests
- `test/js/user_agent_identity_shim.test.js` — jsdom behavioural tests
- `test/js_fixtures/ua_identity/*.js` — dumped fixtures (one per engine × form
  factor)
