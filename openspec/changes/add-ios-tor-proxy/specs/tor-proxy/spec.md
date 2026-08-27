## ADDED Requirements

### Requirement: TOR-001 - Embedded Tor runtime on iOS

The system SHALL embed `iCepa/Tor.framework` on iOS and expose its
SOCKS5 listener to the rest of the app via a Flutter method channel
plugin. The runtime SHALL bind only to the loopback interface
(`127.0.0.1`), never to a routable interface, and SHALL pick a SOCKS5
port dynamically via `SocksPort auto` rather than hardcoding `9050`.

#### Scenario: SOCKS5 endpoint is loopback-only

- **WHEN** Tor reaches the `up` state
- **THEN** `TorService.socksEndpoint` returns a host of `127.0.0.1`
- **AND** the port is a number between 1024 and 65535 that Tor chose
  itself
- **AND** no listener is bound on any non-loopback interface

#### Scenario: Hardcoded port 9050 is rejected by code review

- **WHEN** a developer hardcodes `9050` as the SOCKS port anywhere in
  the Tor-routing code path
- **THEN** the unit test
  `test/tor_service_test.dart::TorService never reports 9050` fails
- **AND** the change cannot land

---

### Requirement: TOR-002 - Lazy lifecycle with debounced idle stop

`TorService` SHALL maintain a refcount of clients that need Tor (the
count of sites whose `proxySettings.type == TOR`, plus 1 if
`globalOutboundProxy.type == TOR`).
When the refcount transitions from 0 to >0 the runtime SHALL start;
when it transitions from >0 to 0 a 60-second debounce timer SHALL
start, and the runtime SHALL stop only when the timer fires with the
refcount still at 0. Reactivation during the debounce SHALL cancel
the timer and keep the runtime up.

#### Scenario: First Tor site starts the runtime

- **GIVEN** the app is running with no `TOR` sites and
  `globalOutboundProxy.type != TOR`
- **AND** `TorService.status` is `stopped`
- **WHEN** the user sets a site's proxy type to `TOR` and saves
- **THEN** `TorService.status` transitions to `starting`, then
  `bootstrapping(_)`, then `up`
- **AND** the SOCKS5 endpoint becomes available to webview and
  Dart-side callers

#### Scenario: Clearing the last Tor site debounces shutdown

- **GIVEN** exactly one site has `type = TOR` and Tor is `up`
- **WHEN** the user switches that site off `TOR`
- **THEN** `TorService` schedules a 60-second debounce timer
- **AND** the runtime remains `up` during the debounce
- **AND** when the timer fires with no refcount, the runtime stops

#### Scenario: Reactivation cancels debounce

- **GIVEN** the debounce timer is running with 30 seconds remaining
- **WHEN** the user sets another site's proxy type to `TOR`
- **THEN** the timer is canceled
- **AND** `TorService.status` stays `up` with no new bootstrap
  cycle

---

### Requirement: TOR-003 - Per-site stream isolation via SOCKS auth

`TorService.socksFor` SHALL materialize SOCKS5 settings whose username is the requesting site's `siteId` (or the reserved literal `__webspace_app_global__` for app-global Dart-side traffic) and whose password is a per-app-launch random secret. Tor SHALL be configured with `SocksPort … IsolateSOCKSAuth IsolateDestAddr` so distinct username/password tuples force distinct circuits.

#### Scenario: Two Tor sites get distinct exit IPs

- **GIVEN** site A (`siteId = a1`) and site B (`siteId = b2`) both
  have `type = TOR`
- **WHEN** both sites are loaded concurrently in container mode and
  each fetches `https://check.torproject.org/`
- **THEN** the JSON response shows two distinct exit IP addresses
- **AND** the response for site A and site B never share a circuit
  identifier (verified via Tor control port `GETINFO circuit-status`)

#### Scenario: App-global traffic isolates from per-site

- **GIVEN** the global outbound proxy is `TOR` and site A has
  `type = TOR`
- **WHEN** the DNS blocklist downloader and site A's favicon fetcher
  both run
- **THEN** the SOCKS5 username for the DNS download is
  `__webspace_app_global__`
- **AND** the SOCKS5 username for site A's favicon fetch is `a1`
- **AND** the two requests use distinct Tor circuits

#### Scenario: Session secret rotates per app launch

- **GIVEN** the app launches and `TorService` generates a
  32-byte hex password
- **WHEN** the app is force-quit and relaunched
- **THEN** the new `TorService` instance generates a different
  password
- **AND** previously-built circuits from the prior launch are not
  reused (cannot be: different SOCKS auth tuple)

---

### Requirement: TOR-004 - Bootstrap status surface

`TorService` SHALL expose a broadcast `Stream<TorStatus>` whose events
are one of `stopped`, `starting`, `bootstrapping(0..100)`, `up`,
`error(message)`. The App Settings screen SHALL render a status card
that subscribes to this stream, showing the current state and a
progress bar during bootstrap. The per-site Settings screen SHALL
show a small inline indicator next to the proxy-type row when
status is anything other than `up`.

#### Scenario: Settings card reflects bootstrap progress

- **GIVEN** Tor is in state `bootstrapping(45)`
- **WHEN** the user opens App Settings → Tor
- **THEN** the status card shows "Bootstrapping… 45%"
- **AND** a determinate progress indicator is rendered at 45%

#### Scenario: Error state surfaces the message

- **GIVEN** Tor fails to bootstrap and `TorService` transitions to
  `error("could not connect to any directory authority")`
- **WHEN** the user opens App Settings → Tor
- **THEN** the status card shows the error message
- **AND** a "Retry" button is rendered that calls
  `TorService.maybeStart` again

---

### Requirement: TOR-005 - On-demand circuit rebuild

The system SHALL expose a "Rebuild circuits" action in App Settings →
Tor that issues `SIGNAL NEWNYM` over Tor's control port. After
`NEWNYM`, subsequent new streams SHALL use fresh circuits; existing
long-lived connections (WebSockets, HTTP/2 streams already open) are
not forced to migrate.

#### Scenario: Rebuild changes the exit IP within 10 seconds

- **GIVEN** Tor is `up` and a `TOR` site's last
  `https://check.torproject.org/` response showed exit IP X
- **WHEN** the user taps "Rebuild circuits"
- **AND** the same site re-fetches `https://check.torproject.org/`
- **THEN** the response shows an exit IP different from X within 10
  seconds (probabilistically — Tor may very rarely re-select the
  same node; tests retry once)

#### Scenario: Rebuild does not interrupt non-Tor sites

- **GIVEN** site A has `type = TOR` and site B does not
- **WHEN** the user taps "Rebuild circuits" while both sites are
  loaded
- **THEN** site B's connection is unaffected
- **AND** site A's next request opens a new circuit

---

### Requirement: TOR-006 - Background grace window integration

`BackgroundTaskService` SHALL keep `TorService` running through its ~30-second `beginBackgroundTask` grace window on iOS app pause if at least one notification site has `proxySettings.type == TOR`, and the `BGAppRefreshTask` registered for notification sites SHALL pre-warm Tor (call `maybeStart` and await `up`) before reloading any `TOR` notification site so the reload does not cold-bootstrap.

#### Scenario: Notification + Tor site keeps Tor alive during pause

- **GIVEN** site N has `notificationsEnabled=true` and `type = TOR`
- **WHEN** the app moves to background
- **THEN** `BackgroundTaskService.beginBackgroundTask` is invoked
- **AND** `TorService` does not enter the idle-stop debounce while
  the grace window is open
- **AND** notifications from site N continue to be delivered through
  Tor

#### Scenario: BGAppRefreshTask pre-warms Tor

- **GIVEN** site N has `notificationsEnabled=true` and `type = TOR`
- **AND** the OS dispatches `BGAppRefreshTask`
- **WHEN** the task handler runs
- **THEN** `TorService.maybeStart` is awaited until `up` (or fails)
- **AND** only then does the handler trigger site N's reload

---

### Requirement: TOR-007 - Platform gate

`TorService` SHALL only operate on iOS in the first cut. On every
other platform `TorService.isAvailable` SHALL return `false`, and
the `TOR` option SHALL be absent from the per-site proxy-type dropdown. Existing
per-site SOCKS5 configuration (manual `host:port`, with or without
credentials) SHALL remain available on every platform that supports
proxies today, so Android users can still point at Orbot's SOCKS5
endpoint manually.

#### Scenario: Android hides the Tor switch

- **GIVEN** the app is running on Android
- **WHEN** the user opens a site's Proxy settings block
- **THEN** the "Route through Tor" switch is not rendered
- **AND** the manual proxy fields are rendered as before

#### Scenario: macOS hides the Tor switch (initial release)

- **GIVEN** the app is running on macOS
- **WHEN** the user opens a site's Proxy settings block
- **THEN** the "Route through Tor" switch is not rendered
- **AND** the manual proxy fields are rendered as before

#### Scenario: iOS renders the Tor switch

- **GIVEN** the app is running on iOS
- **WHEN** the user opens a site's Proxy settings block
- **THEN** the "Route through Tor" switch is rendered above the
  manual proxy fields
- **AND** turning it on hides the manual `host:port` / credentials
  inputs (the values persist underneath but are inert)

---

### Requirement: TOR-008 - Fail-closed before bootstrap

The system SHALL fail closed when a `TOR` request originates while `TorService.status != up`: Dart-side seams via `outboundHttp.clientFor` MUST return `OutboundClientBlocked` (never falling back to a direct connection), and webview navigation MUST be intercepted and rewritten to a Flutter-rendered bootstrap interstitial (`webspace://tor-bootstrap?next=<encoded>`) which auto-resumes navigation once `up`.

#### Scenario: Pre-bootstrap favicon fetch fails closed

- **GIVEN** site A has `type = TOR` and `TorService.status == bootstrapping(20)`
- **WHEN** the favicon stream runs for site A
- **THEN** `outboundHttp.clientFor(torSettings)` returns
  `OutboundClientBlocked`
- **AND** no TCP socket is opened to any host
- **AND** the favicon falls back to the cached/default favicon
  rather than fetching directly

#### Scenario: Pre-bootstrap webview navigation shows interstitial

- **GIVEN** site A has `type = TOR` and `TorService.status == starting`
- **WHEN** the user activates site A
- **THEN** the WebView loads
  `webspace://tor-bootstrap?next=<original-url>`
- **AND** a progress bar bound to `TorService.statusStream` renders
- **AND** when status reaches `up`, the WebView navigates to the
  original URL automatically

#### Scenario: Error state surfaces, never falls through

- **GIVEN** `TorService.status == error("…")`
- **WHEN** any `TOR` request originates
- **THEN** Dart-side seams return `OutboundClientBlocked`
- **AND** webview navigation stays on the interstitial showing
  the error and a "Retry" button
- **AND** no request is ever attempted directly (without Tor)

---

### Requirement: TOR-009 - Control-cookie and ephemeral state isolation

Tor's control-port authentication cookie SHALL live only inside
`Tor.framework`'s sandbox container (`NSCachesDirectory/Tor/`) and
SHALL NOT be exposed through any Dart bridge, JSON serialization,
or settings backup. The session SOCKS password (TOR-003) SHALL live
only in `TorService` memory and SHALL be discarded on app
termination.

#### Scenario: Settings backup never contains Tor secrets

- **GIVEN** Tor is `up` and at least one `TOR` site exists
- **WHEN** the user exports settings via Settings → Backup
- **THEN** the resulting JSON contains no Tor control-cookie bytes
- **AND** the JSON contains no SOCKS5 password material
- **AND** the regression test
  `test/settings_backup_test.dart::Tor secrets never appear in
  exports` asserts neither the cookie nor the session secret string
  appears anywhere in the serialized output

---

### Requirement: TOR-010 - Export compliance declaration

Embedding Tor ships `tor`'s own TLS and onion-routing cryptography
plus a full OpenSSL build inside the app binary. That is encryption
the app *implements*, not encryption provided by the operating
system, so it does not fall under the OS-provided/HTTPS exemption.
`ITSAppUsesNonExemptEncryption` in
[ios/Runner/Info.plist](../../../../ios/Runner/Info.plist) SHALL be
`true` from the first build that links Tor.framework, and the App
Store Connect export-compliance documentation SHALL be filed before
that build is submitted.

This supersedes the pre-existing `false` declaration, which is
already questionable on its own terms: the app implements AES at
rest in [archive_crypto.dart](../../../../lib/services/archive_crypto.dart)
and [html_cache_service.dart](../../../../lib/services/html_cache_service.dart).
Flipping the key is therefore a correction the app owes regardless
of Tor, not a new cost introduced by this change.

#### Scenario: Info.plist declares non-exempt encryption

- **GIVEN** the iOS target links Tor.framework
- **WHEN** `ios/Runner/Info.plist` is read
- **THEN** `ITSAppUsesNonExemptEncryption` is `true`
- **AND** no build declaring `false` is submitted to App Store Connect

#### Scenario: Year-end self-classification is tracked

- **GIVEN** a build containing Tor.framework was distributed in a
  calendar year
- **WHEN** the following 1 February approaches
- **THEN** the annual self-classification report to the U.S. Bureau
  of Industry and Security is filed for that build
- **AND** the obligation is recorded in the release checklist, not
  left to memory

---

### Requirement: TOR-011 - Privacy manifest as a resource, not Info.plist

Required-reason API declarations SHALL live in a
`PrivacyInfo.xcprivacy` resource inside the app bundle.
`NSPrivacyAccessedAPITypes` SHALL NOT be added to `Info.plist` —
that is not where Apple reads it, so a declaration placed there is
silently absent at review time.

The repository ships no privacy manifest today, so this change
introduces the first one. The app declares its own required-reason
API usage; Tor.framework declares its own in its bundle, and a pod
that ships none SHALL be treated as an unmet review dependency and
raised upstream rather than papered over from the app's manifest.

#### Scenario: Manifest lives in the right file

- **WHEN** the iOS bundle is inspected after a release build
- **THEN** `PrivacyInfo.xcprivacy` is present in the app bundle
- **AND** it carries the `NSPrivacyAccessedAPITypes` rows for the
  required-reason APIs the app itself calls
- **AND** `Info.plist` contains no `NSPrivacyAccessedAPITypes` key

---

### Requirement: TOR-012 - Trademark discipline for the Tor marks

The Tor Project's trademark policy permits an open-source,
non-commercial project to use "Tor" in an accurate *description* of
what it does, and forbids using the marks in a product name,
software title, trade name, or domain name. App Store Review
Guideline 5.2.5 rejects apps that use a third-party mark without
rights.

The app SHALL therefore refer to the feature descriptively ("Route
this site through the Tor network") and SHALL NOT: use "Tor" in the
app name, subtitle, or bundle identifier; ship the Tor onion logo or
a derivative as an app icon, tab icon, or badge; or imply
endorsement by, or affiliation with, the Tor Project anywhere in the
UI or App Store metadata.

#### Scenario: Localized strings describe rather than brand

- **WHEN** any `lib/l10n/app_*.arb` value mentioning Tor is reviewed
- **THEN** it reads as a description of routing through the Tor
  network
- **AND** it does not present "Tor" as the name of a WebSpace feature,
  mode, or product

#### Scenario: No onion iconography

- **WHEN** the asset catalogue and widget tree are searched
- **THEN** no Tor onion logo or derivative ships as an icon or badge
- **AND** the per-site indicator uses a generic routing/shield glyph
  from the existing icon set

---

### Requirement: TOR-013 - Reviewer-legible failure, never a hang

App Review runs on a corporate network where Tor bootstrap may be
slow, throttled, or blocked outright. A reviewer who enables the
toggle and sees an indefinite spinner will read it as a broken
feature and reject under Guideline 2.1 (App Completeness). This is
the most probable rejection path for the change, and it is a UX
requirement rather than a policy one.

The bootstrap interstitial (TOR-008) SHALL always resolve to either
progress or a plain-language error within the 90-second timeout, and
SHALL never present an unbounded spinner. The App Review notes
submitted with the build SHALL explain that the toggle starts an
embedded Tor client, that first bootstrap can take 10-30 seconds,
and that a restrictive network surfaces an explicit error by design.

#### Scenario: Blocked network surfaces an error, not a spinner

- **GIVEN** the device network blocks Tor directory authorities
- **WHEN** the user enables Tor on a site and navigates
- **THEN** the interstitial shows a determinate progress bar while
  bootstrapping
- **AND** within 90 seconds it shows a plain-language error with a
  Retry button
- **AND** at no point does the UI present a spinner with no timeout

#### Scenario: Review notes accompany the submission

- **WHEN** the build linking Tor.framework is submitted
- **THEN** the App Review notes describe the feature, the expected
  bootstrap duration, and the expected behavior on a restricted
  network

---

### Requirement: TOR-014 - Per-site strict exit country

A site MAY pin the country its Tor traffic exits from. The pin SHALL be
strict: when no exit in that country is usable, the request fails rather
than silently leaving from somewhere else.

**The constraint that shapes this.** `ExitNodes` and `StrictNodes` are
global client options in `tor(1)` — unlike the isolation flags, they
cannot be scoped to a `SocksPort` line, so the SOCKS auth tuple that
gives each site its own circuit (TOR-003) cannot also give each site its
own country. Nor can we run one tor per country: `TORThread` exposes a
single class-level `activeThread` and tor keeps process-global state, so
one instance per process is the hard ceiling.

Per-site country is therefore delivered the way this app already
delivers per-site proxies on Android — a **serialised global override**
(PROXY-008). The consequence is explicit, not incidental: two loaded
sites whose exit constraints differ cannot coexist, because the single
`ExitNodes` value cannot be two things at once. Activating one SHALL
unload the other, exactly as a mismatched proxy does today. Only sites
sharing the same constraint coexist.

**An unpinned Tor site is a constraint, not an absence of one.** "No
pin" SHALL be read as "must be unrestricted", so an unpinned Tor site
conflicts with a pinned one in both directions. The alternative reading,
that null means "no opinion" and never conflicts, produces exactly the
mis-routing this requirement exists to prevent: with one global
`ExitNodes`, an unpinned site loaded beside a `{de}` site exits from
Germany too, silently, on account of a setting belonging to a site the
user was not looking at. Sites that do not route through Tor at all are
unaffected and SHALL NOT be unloaded — `ExitNodes` says nothing about
where their traffic goes.

A site left on the default proxy takes its constraint from the
app-global proxy, so inheriting a globally pinned Tor does not read as
unpinned.

This costs iOS the concurrent-container property for differently-pinned
sites. That is the price of the feature being honest; the alternative —
applying one site's country to another site's traffic — is the silent
mis-routing the whole fail-closed posture exists to prevent.

#### Scenario: A pinned site exits from its country

- **GIVEN** site A has `torExitCountry = "de"`
- **WHEN** site A loads and Tor is `up`
- **THEN** `ExitNodes` is `{de}` and `StrictNodes` is `1`
- **AND** site A's traffic leaves the Tor network from a German exit

#### Scenario: Two differently-pinned sites do not coexist

- **GIVEN** site A is loaded with `torExitCountry = "de"`
- **AND** site B has `torExitCountry = "nl"`
- **WHEN** the user activates site B
- **THEN** site A is unloaded before `ExitNodes` flips to `{nl}`
- **AND** site A never issues a request from a Dutch exit

#### Scenario: Same-country sites coexist

- **GIVEN** site A and site B both have `torExitCountry = "de"`
- **WHEN** both are activated in turn
- **THEN** neither is unloaded for an exit-country mismatch

#### Scenario: An unpinned Tor site does not coexist with a pinned one

- **GIVEN** site A is loaded with `torExitCountry = "de"`
- **AND** site C routes through Tor with no pin
- **WHEN** the user activates site C
- **THEN** site A is unloaded before `ExitNodes` is cleared
- **AND** site C never issues a request from a German exit

#### Scenario: A site that does not use Tor is never unloaded for a pin

- **GIVEN** site A is loaded with `torExitCountry = "de"`
- **AND** site D uses `ProxyType.SOCKS5`
- **WHEN** the user activates site D
- **THEN** site A stays loaded and `ExitNodes` stays `{de}`

#### Scenario: Clearing the pin restores unrestricted exits

- **GIVEN** site A is loaded with `torExitCountry = "de"`
- **WHEN** the user clears A's country in settings
- **THEN** `ExitNodes` and `StrictNodes` are reset without waiting for a
  site switch, since clearing a setting never re-activates the site
- **AND** subsequent circuits may exit from any country

The value in force SHALL be derived from the sites that are loaded, not
from the last one activated: a pin the user has removed, or one whose
site is gone, must not linger and apply itself to whatever loads next.

#### Scenario: A strict pin with no usable exit fails visibly

- **GIVEN** site A is pinned to a country with no reachable exit
- **WHEN** site A navigates
- **THEN** the request fails and the failure is surfaced to the user
- **AND** the traffic does NOT leave from another country instead
