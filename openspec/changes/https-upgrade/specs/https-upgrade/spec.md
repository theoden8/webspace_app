# HTTPS upgrade

## ADDED Requirements

### Requirement: HTTPS-001 - A plain-http main-frame navigation is retried over https

When the upgrade is enabled for a site, a main-frame navigation to an
`http://` URL SHALL be replaced by the same URL with the scheme `https`, the
host, port, path, query and fragment unchanged. The decision SHALL be made by
`HttpsUpgradeEngine`, which is pure: no Flutter, no platform channel, no
network.

Sub-frames and sub-resources SHALL NOT be upgraded (see HTTPS-004). The engine
is what covers a host nothing has vouched for: every host on Android and Linux,
and the ones WebKit does not already know on iOS and macOS (see HTTPS-006).

#### Scenario: A plain-http site loads over https

**Given** a site whose URL is `http://example.com/login.php?a=1#x`
**And** the upgrade is enabled
**When** the main frame navigates to it
**Then** the engine returns `https://example.com/login.php?a=1#x`
**And** the URL the user sees is the https one

#### Scenario: An https URL is left alone

**Given** a navigation to `https://example.com/`
**When** the engine is consulted
**Then** it returns null and the navigation proceeds unchanged

#### Scenario: A non-http scheme is left alone

**Given** a navigation to `file:///import.html`, `about:blank`,
`data:text/html,x`, `intent://…` or `webspace://open?url=…`
**When** the engine is consulted
**Then** it returns null for each

---

### Requirement: HTTPS-002 - A failed upgrade falls back silently, once per host

An upgraded navigation that fails to load SHALL fall back to the original
`http://` URL. The failure SHALL NOT surface an interstitial, a prompt, or an
error page of the app's own.

The host SHALL then be recorded as http-only for the remainder of the process,
and no later navigation to that host SHALL be upgraded, so a host without TLS
costs one failed connection per launch rather than one per navigation.

The record SHALL be in memory only. It SHALL NOT be persisted, exported, or
keyed by `siteId`: a per-host file would be state that varies with which sites
exist (ARCH-001), and a wrong entry would outlive the condition that caused it
with nothing in the UI to show or clear it.

#### Scenario: An http-only host falls back and is remembered

**Given** the upgrade is enabled and `http://intranet.example/` was upgraded
**When** the https attempt fails
**Then** the engine returns `http://intranet.example/` to load
**And** a later navigation to `http://intranet.example/other` is not upgraded

#### Scenario: The fallback is not itself upgraded

**Given** the fallback `http://intranet.example/` is now loading
**When** the engine is consulted for it
**Then** it returns null, and no second upgrade is attempted

#### Scenario: A failure on a URL that was never upgraded is not a fallback

**Given** `https://example.com/` was navigated to directly and failed
**When** the engine is asked for a fallback
**Then** it returns null: the engine only reverses its own upgrades, and
downgrading a URL the site asked for over https would be an attack, not a
recovery

---

### Requirement: HTTPS-003 - Hosts that cannot be expected to serve TLS are skipped

The engine SHALL NOT upgrade a URL whose host is an IP literal (v4 or v6), a
single-label name (`localhost`, `nas`), or ends in `.local`, and SHALL NOT
upgrade a URL carrying an explicit port other than 80.

These are LAN devices, developer servers and ad-hoc services. They routinely
have no certificate that would validate, so upgrading them buys a guaranteed
failed connection and a fallback on every launch, and on a device with a captive
portal it buys a visible stall.

A URL with an explicit `:80` SHALL be upgraded, losing the port, since `:80` is
the default it would have had anyway.

#### Scenario: A LAN address is left alone

**Given** navigations to `http://192.168.1.10/`, `http://[fd00::1]/`,
`http://localhost:8080/`, `http://nas/` and `http://printer.local/`
**When** the engine is consulted
**Then** it returns null for each

#### Scenario: A non-default port is left alone

**Given** a navigation to `http://example.com:8080/app`
**When** the engine is consulted
**Then** it returns null

#### Scenario: An explicit default port upgrades and drops the port

**Given** a navigation to `http://example.com:80/app`
**When** the engine is consulted
**Then** it returns `https://example.com/app`

---

### Requirement: HTTPS-004 - The upgrade follows the navigation verdict

The upgrade SHALL be applied only after the navigation decision for the
original URL has allowed it: in `shouldOverrideUrlLoading` after
`config.shouldOverrideUrlLoading` has returned, and never before.

Taken first, the engine and the nested-url-blocking rules would see a URL the
site never asked for, and a scheme rewrite would become a way to re-enter the
navigation pipeline with `blockAutoRedirects`, the user-gesture requirement and
cross-domain nested routing already behind it. This is the same ordering
CAPTCHA-008 had to impose on the captcha allow after the fact.

#### Scenario: A blocked navigation is not upgraded into an allowed one

**Given** a site with `blockAutoRedirects` on and no recent gesture
**When** a script-driven navigation to `http://elsewhere.example/` is decided
**Then** the navigation decision engine sees `http://elsewhere.example/`
**And** its verdict is honored before the upgrade is considered
**And** a blocked verdict means nothing is loaded, upgraded or not

The captcha verification popup (CAPTCHA-004/009) is likewise out of scope. It
is built as a fresh native webview attached to an `onCreateWindow` window id,
where a `loadUrl` issued before the window handover completes is not safe on
Android, and its own `shouldOverrideUrlLoading` already refuses any main-frame
navigation that is neither a captcha URL nor the site's own domain. Both are
https in practice.

#### Scenario: The captcha popup is not upgraded

**Given** a verification popup open for a challenge
**When** it navigates its main frame
**Then** the engine is not consulted, and CAPTCHA-010's allowlist decides

#### Scenario: Sub-resources never reach the engine

**Given** a page over https that loads `http://cdn.example/x.js`
**When** the sub-resource is requested
**Then** the engine is not consulted: mixed-content handling is the engine's,
and rewriting a sub-resource on Android would route it through
`FastSubresourceInterceptor`, whose block response is an empty `200` rather
than an error

---

### Requirement: HTTPS-005 - A global default-on knob, with a per-site override

The upgrade SHALL be controlled by a global `httpsUpgradeEnabled` preference
registered in `kExportedAppPrefs` with the default `true`, and a per-site
`WebViewModel.httpsUpgradeEnabled` override for a site that has no TLS at all.

The per-site value SHALL ride `toJson`/`fromJson`, the `WebViewConfig`, the
`launchUrl` signature and the nested `InAppWebViewScreen`, per the per-site
field checklist: a nested webview that keeps loading plaintext while the parent
upgrades is the same silent bypass that checklist exists to prevent.

`effectiveHttpsUpgradeEnabled` SHALL be true when Tracking Protection is on
(ETP-028), otherwise the per-site value.

#### Scenario: On by default

**Given** a fresh install and a newly added site
**When** the site navigates to an http URL
**Then** the navigation is upgraded

#### Scenario: A site that genuinely has no TLS

**Given** a site with `httpsUpgradeEnabled` false and the umbrella off
**When** it navigates to an http URL
**Then** the navigation is not upgraded

#### Scenario: The global default survives a backup round-trip

**Given** `httpsUpgradeEnabled` is false app-wide
**When** settings are exported and re-imported
**Then** it is false after the import

---

### Requirement: HTTPS-006 - The platform's own known-host upgrade stays on

`InAppWebViewSettings.upgradeKnownHostsToHTTPS` SHALL be left at its default
`true`. The app SHALL NOT set it to false, and SHALL NOT reimplement what it
does.

It maps to `WKWebViewConfiguration.upgradeKnownHostsToHTTPS` (iOS 15.0+, macOS
11.3+) and upgrades http requests to servers *already known to support https*,
which is WebKit's HSTS knowledge: the preload list plus origins that have sent
the header before. It acts inside the network layer, before any navigation
callback, so an upgrade it performs never reaches `shouldOverrideUrlLoading` as
http and the engine simply sees an https URL and returns null. The two do not
race and do not double-upgrade.

It is not a substitute for HTTPS-001 on either count: the android plugin has no
implementation of it at all, and "known" excludes exactly the origin that
prompted this change, which serves both schemes and sends no
`Strict-Transport-Security`.

#### Scenario: A known host is upgraded before the engine sees it

**Given** an iOS or macOS site navigating to `http://known-hsts.example/`
**When** WebKit upgrades it
**Then** the navigation callback receives an https URL
**And** the engine returns null for it, having nothing to do

#### Scenario: Android has no such flag

**Given** the same navigation on Android
**Then** nothing upgrades it before the engine
**And** HTTPS-001 is the only thing that will
