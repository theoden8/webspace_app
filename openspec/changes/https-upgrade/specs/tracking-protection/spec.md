# Enhanced Tracking Protection — https upgrade delta

## ADDED Requirements

### Requirement: ETP-030 - HTTPS upgrade forced on under umbrella

The umbrella SHALL force the HTTPS upgrade (HTTPS-001) to behave as on whenever
`trackingProtectionEnabled` is true, regardless of the stored per-site value,
and the Privacy row SHALL render `onChanged: null` with `value: true` while the
umbrella is on. Turning the umbrella off SHALL restore the stored value, not
`false`, mirroring ETP-002.

Plaintext http is a tracking channel the app's other defences cannot reach: an
on-path observer reads the full URL of every request, and an injecting
middlebox adds trackers that no filter list of ours has ever seen. Forcing the
upgrade closes the umbrella's largest remaining hole in the same sense ETP-024
closes third-party cookies.

The upgrade SHALL NOT be a subordinate of the umbrella in the ETP-002 sense —
one whose only home is Tracking Protection and whose stored default is off. It
SHALL have a global default of `true` independent of the umbrella (HTTPS-005).

Tracking Protection is the switch a user turns off to make a broken site work;
the app's own support guidance says so, because the anti-fingerprinting noise
and the third-party-cookie forcing sometimes require it. If the upgrade were
reachable only through the umbrella, then debugging a captcha would silently
downgrade a login page to cleartext, with nothing said to the user. A security
default MUST NOT be collateral of a privacy toggle.

#### Scenario: Stored upgrade disabled, umbrella on

**Given** `httpsUpgradeEnabled` is false and `trackingProtectionEnabled` is true
**When** the webview is constructed
**Then** the `WebViewConfig` has `httpsUpgradeEnabled: true`
**And** the same forcing applies to nested webviews opened by `launchUrl`

#### Scenario: Umbrella off restores the stored value, not off

**Given** `httpsUpgradeEnabled` is true, `trackingProtectionEnabled` goes false
**When** the webview is constructed
**Then** the `WebViewConfig` has `httpsUpgradeEnabled: true`

#### Scenario: Turning the umbrella off to debug a site keeps https

**Given** a site with the umbrella on and the global default untouched
**When** the user turns Tracking Protection off for that site
**Then** its navigations are still upgraded
**And** nothing the user did to a privacy control moved them to cleartext
