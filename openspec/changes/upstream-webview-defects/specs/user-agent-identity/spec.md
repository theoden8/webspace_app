# User Agent Identity

## ADDED Requirements

### Requirement: UAID-005 - UA Client Hints Fail Closed

UAID-002 requires the JS navigator identity to stay consistent with the
per-site UA string. The same consistency MUST hold on the wire. Android sends
`Sec-CH-UA`, `Sec-CH-UA-Platform`, `Sec-CH-UA-Mobile` and friends from
`WebSettingsCompat.setUserAgentMetadata`, and those headers are a second,
independent statement of identity that a site can compare against both the UA
string and `navigator.userAgentData`.

`buildUserAgentMetadata` currently derives the brand list by matching `Firefox/`
or `Chrome/` in the UA and returns `null` for anything else, while still
returning a metadata object carrying `platform` and `mobile`. The native side
applies a brand list only when it is non-empty, so a null list leaves the
device's **real** brands in place.

The result for any UA carrying neither token, including the shipped
Firefox-for-iOS preset (`FxiOS/`), every WebKit-shaped preset, and every custom
UA a user types, is headers that read `Sec-CH-UA-Platform: "iOS"` beside a
`Sec-CH-UA` naming the true Chromium version and the string "Android WebView".
The site learns the real engine *and* sees a contradiction the unspoofed
configuration would not have produced.

Partial application is therefore forbidden. When a UA is presented for which a
consistent brand list cannot be derived, the implementation MUST do one of:

1. **Synthesize** a brand list matching the engine the UA claims (a
   WebKit/Safari list for a WebKit-shaped UA), with the GREASE entry UAID-004
   already requires; or
2. **Suppress** the metadata override entirely, so platform, mobile and brands
   are all the device's real values and no contradiction is introduced.

What it MUST NOT do is ship some fields spoofed and others real. The same rule
applies when `WebViewFeature.USER_AGENT_METADATA` is unsupported: the override
silently no-ops there, so the JS shim MUST NOT assume the headers agree with it.

#### Scenario: WebKit-shaped UA on Android

- **GIVEN** a site set to the Firefox-for-iOS preset, whose UA carries `FxiOS/`
  and `Safari/` but neither `Firefox/` nor `Chrome/`
- **WHEN** the per-site UA is applied on Android
- **THEN** either the emitted `Sec-CH-UA` names a WebKit/Safari brand set
  consistent with that UA, or no client-hint override is applied at all
- **AND** in no case does the site receive a spoofed `Sec-CH-UA-Platform`
  alongside the device's real `Sec-CH-UA`

#### Scenario: User-typed custom UA

- **GIVEN** a custom UA string the user typed that matches no known brand token
- **WHEN** metadata is built for it
- **THEN** the outcome is one of the two fail-closed options, chosen the same
  way for every unrecognized UA

#### Scenario: Feature unsupported

- **GIVEN** a device whose System WebView lacks
  `WebViewFeature.USER_AGENT_METADATA`
- **WHEN** a per-site UA is applied
- **THEN** the headers stay at their real values
- **AND** the app does not report or assume that client hints were spoofed
