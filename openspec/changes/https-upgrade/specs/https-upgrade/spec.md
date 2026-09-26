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

An upgraded navigation that produces no verdict at all within the engine's
`deadline` SHALL be treated the same way. A refused port errors and reaches
`onReceivedError`; a port that accepts the connection and then says nothing
raises nothing, for as long as the engine's own timeouts allow, so a deadline
armed when the upgrade is issued is the only thing that can rescue it. That is
the shape a firewall blackholing 443 has, which is the shape of a captive
portal, and without the deadline the page hangs on a site that would have
loaded instantly over http.

The deadline SHALL apply only to a connection that has produced nothing. Once
the server has answered for an upgraded navigation, the call site SHALL tell
the engine, and the deadline SHALL stop applying to it: a page that is slow to
finish is not a connection that never got going, and abandoning one downgrades
a working https host for being slow and records it http-only for the rest of
the session. A failure *after* a response is still a failure and SHALL still
fall back.

A deadline that fires after the navigation resolved SHALL be a no-op. It SHALL
reach the fallback through the same call the error path uses, so the in-flight
entry a success removes is what makes it one; a path that re-derived the http
URL would downgrade a page already up over https. It SHALL additionally be
scoped to the navigation that armed it, so a deadline outliving a navigation
the user has left cannot pull them back.

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

#### Scenario: A TLS port that accepts and never answers

**Given** the upgrade is enabled and `http://stalled.example/a` was upgraded
**And** the https port accepts the connection and sends nothing
**When** the deadline passes with no load and no error
**Then** the engine returns `http://stalled.example/a` to load
**And** the host is recorded http-only, so the next navigation does not stall

#### Scenario: A slow https host is not downgraded for being slow

**Given** an upgraded navigation whose server has answered
**And** the page has not finished loading when the deadline passes
**When** the deadline fires
**Then** nothing is loaded, and the host is not recorded http-only

#### Scenario: A failure after a response is still a failure

**Given** an upgraded navigation whose server answered and then failed
**When** the error arrives
**Then** the fallback is taken as usual

#### Scenario: Two upgrades to one host, one certificate failure

**Given** upgrades to `https://h/first` and `https://h/second` both in flight
**When** the trust callback fires for `h`
**Then** `http://h/second` is loaded, being the one the user is waiting on
**And** no upgrade to `h` is left in flight for a later callback to reverse

#### Scenario: A deadline that fires late does nothing

**Given** an upgraded navigation that has already loaded over https
**When** its deadline fires
**Then** the engine returns null, the page is left alone, and the host is not
recorded http-only

#### Scenario: A deadline does not outlive its navigation

**Given** an upgraded navigation whose deadline is still armed
**When** the user navigates somewhere else before it fires
**Then** the fallback is not loaded

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
navigation pipeline with the user-gesture requirement and cross-domain nested
routing already behind it. This is the same ordering
CAPTCHA-008 had to impose on the captcha allow after the fact.

#### Scenario: A blocked navigation is not upgraded into an allowed one

**Given** a site with no recent gesture
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
(ETP-030), otherwise the per-site value.

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

The app SHALL NOT keep an HSTS store of its own. HSTS belongs to the network
stack, and a store here would be per-host state on disk, which HTTPS-002
refuses for the negative cache for the same reasons.

How much HSTS each engine actually applies is NOT established. WKWebView's is
reachable through the flag above. Android WebView is Chromium-based, so
`TransportSecurityState` is presumably in the stack it uses, but that is an
inference: the only account found is a secondary source describing the preload
list being applied to *scheme-less* input, which is a different case from a
navigation explicitly to `http://`, and it says nothing about dynamically set
headers. Nobody has run it. Treat the Android answer as unknown until someone
measures it on a device, and note that a weaker answer there argues for this
capability rather than against it: it would mean the upgrade is the only thing
moving those navigations to https.

The engine's http-only record therefore SHALL be understood as declining to
upgrade, never as forcing plaintext. It suppresses only the app's own
substitution: the URL handed to the platform is the one the site asked for, and
whatever the platform does with it — including upgrading an HSTS host the
engine has stopped touching — is unchanged by this feature. The app cannot
downgrade an https URL, because it only ever reverses an upgrade it made
itself (HTTPS-002).

Whether a given engine re-upgrades such a host is that engine's behaviour and
is NOT measured here. Nothing in this capability depends on it, which is what
makes the unknown above tolerable rather than blocking.

#### Scenario: The negative cache cannot force plaintext

**Given** a host recorded http-only after a failed upgrade
**When** the site navigates to `http://host/`
**Then** the engine returns null and the platform receives the URL the site
asked for, exactly as it would with this feature switched off

#### Scenario: A known host is upgraded before the engine sees it

**Given** an iOS or macOS site navigating to `http://known-hsts.example/`
**When** WebKit upgrades it
**Then** the navigation callback receives an https URL
**And** the engine returns null for it, having nothing to do

#### Scenario: Android has no such flag

**Given** the same navigation on Android
**Then** nothing upgrades it before the engine
**And** HTTPS-001 is the only thing that will

---

### Requirement: HTTPS-007 - An upgrade never asks the user to vouch for a certificate

When an upgraded navigation's certificate does not validate, the app SHALL
cancel the challenge silently, load the original `http://` URL, and record the
host http-only. It SHALL NOT show the untrusted-certificate prompt (TLS-002)
and SHALL NOT pin anything (TLS-007).

A certificate failure does not arrive as a load error on Android or Linux: it
arrives at `onReceivedServerTrustAuthRequest`, whose normal answer is a dialog
asking the user whether to trust the certificate, and whose approval pins it
permanently. For a navigation the *user* made that is the right question. For
one the app substituted it is not a question they can answer: they asked for
`http://host`, never saw an https URL, and have no way to know which of the two
the dialog is about. A yes would pin a certificate the OS rejected, for a host
the user never chose to reach over TLS.

Apple platforms reach the same outcome through the ordinary error path, because
`_handleServerTrust` defers to the OS there and the rejection returns as an SSL
`onReceivedError` — which HTTPS-002's fallback already answers first, ahead of
that handler's SSL branch.

The lookup SHALL be by host: the platform hands the callback a protection space
(host and port), never the URL that asked for it. Where more than one upgrade
to that host is in flight — the root webview and its nested webviews share one
engine (HTTPS-002), so this is reachable — it SHALL reverse the most recent and
clear the rest. Taking whichever the bookkeeping happened to hold first could
load a URL the user has already left, and leaving siblings in flight lets a
later callback reverse one of them over the top of the page that replaced it.

#### Scenario: A self-signed certificate on an upgraded navigation

**Given** a site at `http://selfsigned.example/a` with the upgrade enabled
**And** its https certificate does not validate
**When** the trust callback fires for `selfsigned.example`
**Then** no prompt is shown and nothing is pinned
**And** `http://selfsigned.example/a` is loaded
**And** the host is recorded http-only, so it is not upgraded again

#### Scenario: A certificate failure the user's own navigation caused

**Given** a site the user navigated to over https directly
**When** its certificate does not validate
**Then** the engine reverses nothing
**And** the ordinary TLS-002 prompt is shown, as before this change

---

### Requirement: HTTPS-008 - The engine decides, the call site forwards

Every decision about an upgrade SHALL live in `HttpsUpgradeEngine`. The webview
SHALL call only its event surface — `onNavigation`, `onLoadStarted`,
`onLoadFinished`, `onLoadFailed`, `onCertificateRejected`, `onDeadline` — and
SHALL apply the returned outcome without branching on engine state. The
navigation-generation check SHALL be passed to `onDeadline` as
`(generationAtArm, currentGeneration)`, the repo's race-protection signature,
rather than tested at the call site.

Five platform callbacks can resolve one upgrade, none of which knows about the
others, so every hazard in this feature is an ordering. While those orderings
lived in webview closures the only available cover was asserting which line of
source came before which: that catches a deletion, breaks on reformatting, and
passes on code that is equivalently shaped and wrong. With the decisions in the
engine an ordering is a few lines of a unit test, so the interesting ones can
be enumerated instead of argued about.

What stays structural is what the engine cannot own: that each callback
forwards at all, that the deadline is armed with the engine's own duration and
a generation, and the two positions relative to code the engine cannot see —
the upgrade after the navigation verdict (HTTPS-004) and the certificate
carve-out before the trust prompt (HTTPS-007).

#### Scenario: A decision moves back into a callback

**Given** a callback that calls a primitive such as `fallbackFor` directly
**When** the structural gate runs
**Then** it fails, naming the primitive and the callback

#### Scenario: Orderings are enumerable

**Given** the engine's event surface
**When** a test drives navigate / start / finish / fail / certificate /
deadline in any order
**Then** the outcome is asserted without a webview, a socket or a timer
