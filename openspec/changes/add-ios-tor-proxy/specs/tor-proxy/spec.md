## ADDED Requirements

### Requirement: TOR-001 - Embedded Tor runtime on Apple platforms

The system SHALL embed `iCepa/Tor.framework` on iOS and macOS and
expose its SOCKS5 listener to the rest of the app via a Flutter method
channel plugin. One source SHALL serve both
(`ios/Runner/TorControllerPlugin.swift`, compiled by the iOS and macOS
Runner targets), because the macOS build is what the integration tier
drives (TOR-021) and a copy would drift from what iOS ships. It stays
under the iOS project because iOS is the shipping target: the reference
that may cross a directory boundary is the macOS one. The runtime SHALL bind only to the loopback interface
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

### Requirement: TOR-002 - Lazy start, and no idle stop

`TorService` SHALL maintain a refcount of clients that need Tor (the
count of sites whose `proxySettings.type == TOR`, plus 1 if
`globalOutboundProxy.type == TOR`).
When the refcount transitions from 0 to >0 the runtime SHALL start.

Releasing the last client SHALL NOT stop the runtime. The process gets one
tor for its whole life (TOR-020), so an idle stop spends the app's only
launch to reclaim a loopback listener nobody is using, and the next site
pinned to Tor gets a runtime that cannot come back — which is what "I have
to restart the app for Tor to work" is. The 60-second debounce timer SHALL
still run, because it is what keeps a released-then-reacquired runtime from
re-arming a bootstrap deadline mid-flight; it SHALL end in nothing.

The runtime SHALL be stopped only where the process is going away.

#### Scenario: First Tor site starts the runtime

- **GIVEN** the app is running with no `TOR` sites and
  `globalOutboundProxy.type != TOR`
- **AND** `TorService.status` is `stopped`
- **WHEN** the user sets a site's proxy type to `TOR` and saves
- **THEN** `TorService.status` transitions to `starting`, then
  `bootstrapping(_)`, then `up`
- **AND** the SOCKS5 endpoint becomes available to webview and
  Dart-side callers

#### Scenario: Clearing the last Tor site leaves the runtime up

- **GIVEN** exactly one site has `type = TOR` and Tor is `up`
- **WHEN** the user switches that site off `TOR`
- **THEN** the runtime remains `up`, during the debounce and after it
- **AND** re-pinning a site to `TOR` an hour later still routes, with no
  second bootstrap and no app restart

#### Scenario: Reactivation cancels debounce

- **GIVEN** the debounce timer is running with 30 seconds remaining
- **WHEN** the user sets another site's proxy type to `TOR`
- **THEN** the timer is canceled
- **AND** `TorService.status` stays `up` with no new bootstrap
  cycle

---

### Requirement: TOR-003 - Per-site stream isolation via SOCKS auth

`TorService.socksFor` SHALL materialize SOCKS5 settings whose username is the requesting site's `siteId` (or the reserved literal `__webspace_app_global__` for app-global Dart-side traffic) and whose password is a per-app-launch random secret. Tor SHALL be configured with `SocksPort … IsolateSOCKSAuth` so distinct username/password tuples force distinct circuits.

Circuits SHALL be isolated per site and never per destination: the
`SocksPort` line is `auto IsolateSOCKSAuth`, it carries no `IsolateDestAddr`,
and nothing in the app can change it. The circuit key is the SOCKS credential
tuple, so `IsolateSOCKSAuth` alone gives each site its own circuit, which is
what this requirement promises.

`IsolateDestAddr` was an app-wide setting ("Separate circuit per
destination", off by default) and was removed. It split each site's circuit
per destination *address*, so one page loading from two hosts exited from two
relays. What that bought was narrow, no single exit relay seeing a whole page
load, and it cost a site one circuit build per host and a client that arrived
from two addresses at once, which a session that checks its own IP across its
hostnames reads as a hijack. It also masked a real defect: while the
credential was being discarded on Apple (BUG-014, instance 3), the flag kept
circuits isolated by destination, so per-site isolation could be entirely
absent while still looking alive.

It cannot come back as a live setting either. A restart is impossible (tor
runs once per process, TOR-020), and `SETCONF SocksPort` is accepted and
changes nothing: `retry_listener_ports` treats an `auto` request as matching
the listener already running and keeps it, with the flags it was opened with,
and tor still answers `250 OK`. The stored `torIsolateDestAddr` preference is
no longer read; an old backup that carries it imports without it.

#### Scenario: One site reaches every host it loads from through one exit

- **GIVEN** site A has `type = TOR` and its page loads from
  `example.com` and `api.example.net`
- **WHEN** the page loads
- **THEN** both hosts see the same exit address
- **AND** tor's `SocksPort` line is `auto IsolateSOCKSAuth`

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

The card SHALL render nothing while the status is `stopped`. Tor starts
when a site or the app-wide proxy first asks for it and does not stop on
its own (TOR-002), so `stopped` means nothing is set to use Tor; a card
reading "Not running" with no action on it reads as a setting the user is
meant to do something with, which is how it was reported.

#### Scenario: Settings card reflects bootstrap progress

- **GIVEN** Tor is in state `bootstrapping(45)`
- **WHEN** the user opens App Settings → Tor
- **THEN** the status card shows "Bootstrapping… 45%"
- **AND** a determinate progress indicator is rendered at 45%

#### Scenario: No card while nothing uses Tor

- **GIVEN** no site and not the app-wide proxy is set to `TOR`
- **WHEN** the user opens App Settings
- **THEN** no Tor card is shown
- **AND** once a site set to `TOR` starts it, the card appears under the
  outbound proxy block

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

`TorService` SHALL operate on iOS and macOS, and nowhere else.
`TorService.isAvailable` SHALL be that platform check and nothing more,
and SHALL be the single reader both the per-site and app-global proxy-type
dropdowns consult; with it false the `TOR` option SHALL be absent from both.
Existing per-site SOCKS5 configuration (manual `host:port`, with or without
credentials) SHALL remain available on every platform that supports proxies
today, so Android users can still point at Orbot's SOCKS5 endpoint manually.

**No developer mode, no experimental switch.** Tor was reachable only with
developer mode on and the Experimental group's Built-in Tor switch on
(DEVTOOLS-011). It graduated: the switch, its pref (`experimentalTor`, never
in a release), `TorGate.switchedOff` and the TOR-023 confirmations went with
it, and turning developer mode on or off has no effect on Tor.

It graduated with two of BUG-013's gaps still open, and they are the cost of
shipping it rather than reasons it works. Tor runs at most once per process
(TOR-020), so a session that genuinely loses it (a landed `SIGNAL HALT`, a
bridge edit, a tor that exits on its own) cannot get it back until the app
restarts; the failure names itself and says so (TOR-015) rather than hanging.
And no tier runs the plugin on iOS; the macOS tier runs the real handshake
(TOR-021).

**Where the gate lives.** On `TorService`, not on `MethodChannelTorRuntime`
or `TorEngine`, which are unit-tested against a fake. Every start path on
`TorService` SHALL re-check it, so no channel is touched on a platform
without the plugin whether or not the caller asked first, and `socksFor`
SHALL return null there: a site carrying `ProxyType.TOR` imported from an
Apple device is blocked, never quietly sent out over the device IP.

**macOS carries it on the same terms as iOS.** It is the platform whose
integration tier can run the real control-port handshake (TOR-021). Both
platforms SHALL pin the same pod versions: a skew would mean the tier tests
something other than what iOS ships.

The macOS floor moves with the pod. `Tor` is a macOS 11 pod, so
`platform :osx`, `MACOSX_DEPLOYMENT_TARGET` and the
`LSMinimumSystemVersion` that derives from it are 11.0, and macOS 10.15
is no longer a supported floor — state it in the listing
([docs/releasing-macos.md](../../../../../docs/releasing-macos.md)).

#### Scenario: Tor is offered with developer mode off

- **GIVEN** the app is running on iOS with developer mode off
- **WHEN** the user opens a site's Network settings
- **THEN** `TOR` is offered in the proxy-type dropdown
- **AND** App settings' Experimental group lists no Tor switch

#### Scenario: Turning developer mode off leaves Tor sites routed

- **GIVEN** a site is routed through Tor and the runtime is up
- **WHEN** the user turns developer mode off
- **THEN** no confirmation is asked
- **AND** the site keeps loading through Tor

#### Scenario: Android does not offer Tor

- **GIVEN** the app is running on Android
- **WHEN** the user opens a site's Network settings
- **THEN** `TOR` is absent from the proxy-type dropdown
- **AND** the manual proxy fields are rendered as before

#### Scenario: macOS offers Tor as iOS does

- **GIVEN** the app is running on macOS
- **WHEN** the user opens a site's Network settings
- **THEN** `TOR` is offered in the proxy-type dropdown
- **AND** choosing it hides the manual `host:port` / credentials inputs
  (the values persist underneath but are inert)

### Requirement: TOR-008 - Fail-closed before bootstrap

The system SHALL fail closed when a `TOR` request originates while `TorService.status != up`: Dart-side seams via `outboundHttp.clientFor` MUST return `OutboundClientBlocked` (never falling back to a direct connection), and webview navigation MUST be intercepted and rewritten to a Flutter-rendered bootstrap interstitial (`webspace://tor-bootstrap?next=<encoded>`) which auto-resumes navigation once `up`.

On iOS and macOS the webview's proxy is bound once, at construction, so a
binding that goes stale is as bad as one that was never made: tor picks its
loopback port from the OS, a restart comes back on a different one, and a
webview still pointing at the old port reaches nothing while failing closed.
The system SHALL therefore rebuild every TOR-bound webview whenever the SOCKS
endpoint changes — compared as an endpoint, not as "is the runtime up", since
a restart is `up` on both sides of the change.

#### Scenario: A restart on a new port rebinds the sites

- **GIVEN** site A has `type = TOR` and a webview built while the runtime was
  `up(127.0.0.1:50496)`
- **WHEN** the runtime restarts and reports `up(127.0.0.1:50818)`
- **THEN** site A's webview is disposed and rebuilt against the new endpoint
- **AND** the user does not have to restart the app for the site to load

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
the app *implements*, so Apple's OS-provided/HTTPS and
authentication-only exemptions do not cover it.

They are not what covers it. `ITSAppUsesNonExemptEncryption` in
[ios/Runner/Info.plist](../../../../ios/Runner/Info.plist) SHALL
remain `false` under EXPORT-001's basis: the source is publicly
available under MIT and the object code is therefore not subject to
the EAR (note to 15 CFR 734.3(b)(3), 742.15(b)(1)). Tor changes what
cryptography ships; it does not change whether the source is public.

An earlier revision of this requirement mandated `true`, on the
reasoning that the app implements rather than borrows its
cryptography. That is true and beside the point: it rebuts the
OS-provided exemption, which EXPORT-001 never invoked. The
consequence was concrete, not academic. `true` obliges an
`ITSEncryptionExportComplianceCode` that Apple issues only after
approving uploaded documentation, so every upload was rejected with
ITMS-90592 ("the export compliance key value [] ... doesn't match")
until the key was reverted.

No 15 CFR 742.15(b)(2) notification is owed either: it reaches only
source code performing "non-standard cryptography", and everything
the app and the Tor pod use is a published standard. See EXPORT-001
for the full argument and EXPORT-002 for the primitive list that
keeps it true.

#### Scenario: Info.plist declares exempt encryption

- **GIVEN** the iOS target links Tor.framework
- **WHEN** `ios/Runner/Info.plist` is read
- **THEN** `ITSAppUsesNonExemptEncryption` is `false`
- **AND** no `ITSEncryptionExportComplianceCode` is present, since an
  exempt declaration carries no code

#### Scenario: A build is submitted

- **GIVEN** an IPA built from this source
- **WHEN** it is uploaded to App Store Connect
- **THEN** it is not rejected for export compliance
- **AND** [scripts/check_export_compliance.sh](../../../../scripts/check_export_compliance.sh)
  exits non-zero before the upload if the two keys ever disagree

#### Scenario: The declaration is set to true

- **GIVEN** a change sets `ITSAppUsesNonExemptEncryption` to `true`
- **THEN** `ITSEncryptionExportComplianceCode` carries the code Apple
  issued after approving export documentation, never a placeholder
- **AND** the documentation is filed and approved before the build is
  submitted, since the code does not exist beforehand

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
SHALL never present an unbounded spinner. The deadline SHALL be a report
and not a teardown: tor keeps trying on its own, and stopping it there
spends the process's one launch (TOR-020) on a network outage that may
already be over. The App Review notes
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

tor takes a pin to a country whose relays include no exit, then builds no
circuit at all: its path check finds no exit bandwidth and it stops
treating its directory as usable, for every stream, not only the pinned
site's. Nothing on the control port reports this until a stream times out,
so the runtime SHALL count the consensus relays carrying the Exit flag (and
not BadExit) that tor's GeoIP table places in the pinned country before it
applies the pin. None is a failure of kind `exitPolicy`, reported at once
rather than after a page's own timeout, and the pin SHALL NOT reach tor:
once tor has judged its directory unusable under such a pin it does not
judge again when `ExitNodes` changes, only when its directory does, so the
next country's first loads stalled behind a pin that was already gone. The
sites pinned to the country stay blocked by the engine (TOR-008), so
nothing leaves from another country instead.

#### Scenario: A pin to a country with no exit is reported when it is applied

- **GIVEN** Tor is `up` and tor's consensus has no exit in country X
- **WHEN** a site pinned to X is activated
- **THEN** the runtime answers the pin with an `exitPolicy` failure, not `up`
- **AND** tor's `ExitNodes` is not `{x}`
- **AND** no site is handed a SOCKS route until the pin changes or a Retry
  finds an exit there

#### Scenario: The next pin after a country with no exit loads at once

- **GIVEN** a pin to a country with no exit was just refused
- **WHEN** the pin is cleared or changed to a country with exits
- **THEN** a request through Tor completes without waiting on tor to
  re-read its directory

#### Scenario: Saving a site's pin unloads a loaded site that disagrees

- **GIVEN** site A is loaded with `torExitCountry = "dk"`
- **AND** site B is the site on screen
- **WHEN** the user saves site B with `torExitCountry = "ca"`
- **THEN** site A is unloaded before `ExitNodes` flips to `{ca}`
- **AND** site A is not rebuilt under `{ca}` when Tor comes back up

Every path that moves the pin reconciles the loaded set first, the site on
screen winning and then the most recently used, not only activation.

**A pin is only in force once tor can resolve it** (BUG-014 instance 7).
tor matches `{cc}`
against its IPv4 GeoIP table, and with no table loaded the pin names no
relay at all. That table SHALL NOT ship with the app: it is the IPFire
Location Database under CC BY-SA 4.0 (LICENSE-002), which rules out
Tor.framework's `Tor/GeoIP` subspec. The device SHALL download tor's own
`src/config/geoip` from the Tor Project, through Tor on an isolation tag of
its own, from the GitLab onion service first and the clearnet host second.
Each request SHALL take a circuit no earlier request took, and a download
SHALL go through both sources twice before it fails: the onion service has
timed out on one circuit while the clearnet host refused that download's exit
with HTTP 403, and tor reuses a circuit for ten minutes, so a Retry on the
same tag went back to both.
It SHALL be kept verbatim, licence header included, in the app's cache
directory, and refused unless its header declares CC BY-SA 4.0. tor has no
updater and re-reads `GeoIPFile` only when the path changes, so every
download SHALL land under a new file name. A table older than 30 days SHALL
be used as it is and refreshed in the background for the next pin. A pin
that only archive-tier sites want SHALL use a kept table and SHALL NOT
download or refresh one (ARCH-006); with none kept it fails closed.

The native side SHALL load the table, confirm `ip-to-country/ipv4-available`,
and only then set `ExitNodes`, so tor never holds a country it cannot read.
Until the pin lands, the engine SHALL NOT publish `up`: every Tor-bound site
waits behind the interstitial and Dart-side Tor fetches block.

A change to `ExitNodes` stops tor attaching new streams to older circuits,
and does nothing to streams already open. The webview pools connections per
data store, so a site recreated for its new pin can reuse a connection
opened under the old one. Every exit-capable circuit (`GENERAL`,
`CONFLUX_*`) SHALL therefore be closed after each pin change.

Closing them is not enough while conflux is on. A conflux set outlives the
change: when one of its legs closes, by tor's own cleanup or ours, tor
launches a recovery leg with the exit its other legs already use, and a new
stream takes any linked set whose exit is not *excluded*, which a pre-pin exit
never is. On a real tor this sent a `{de}` pin out through the Netherlands and
a `{us}` pin out through Germany. A pin SHALL therefore set `ConfluxEnabled 0`
in the same `SETCONF` as `ExitNodes`, before any circuit is closed, and
clearing the pin SHALL return `ConfluxEnabled` to `auto`. With conflux off no
leg can link, so no stream rides a set built before the pin.

**A pin change holds up nothing but the Tor sites it concerns** (BUG-018).
The change is a control-port round trip, and a control connection can go
silent without failing: Tor.framework drops a command's completion when the
write to a dead socket fails, and still reports the controller connected. The
engine SHALL publish its hold before a caller could wait on the change, and no
UI transition SHALL await it. The round trip SHALL be bounded, and on no
answer SHALL fail closed as a control-channel failure with Retry. The native
side SHALL answer every call exactly once, bound every command, and replace a
control connection that stops answering with a fresh one, never with
`disconnect()`, which sends SIGNAL SHUTDOWN. The pin SHALL be recomputed when
memory pressure evicts a site, not left for the next activation.

#### Scenario: A silent control port does not stop a site switch

- **GIVEN** `{br}` is in force for a site memory pressure has since evicted
- **AND** tor's control socket stopped answering while the app was suspended
- **WHEN** the user activates a site that does not use Tor
- **THEN** the switch completes without waiting on tor
- **AND** the clear is attempted off the activation path, fails within its
  bound, and is reported as a control-channel failure with Retry
- **AND** no Tor-bound site loads until a change lands, and later taps do not
  re-send the clear
- **AND** Retry re-attaches a fresh control connection and applies the clear

#### Scenario: A pinned site never reuses the exit it had before

- **GIVEN** site A is loaded through Tor and exits from the Netherlands
- **WHEN** the user pins A to Brazil in its settings
- **THEN** A waits behind the interstitial until `ExitNodes` is `{br}`
- **AND** every circuit that carried exit traffic before the change is closed
- **AND** A's next request leaves from a Brazilian exit, not over a pooled
  connection to the Dutch one

#### Scenario: A conflux set built before a pin carries none of its traffic

- **GIVEN** tor holds linked conflux sets whose exit is in the Netherlands
- **WHEN** site A is pinned to `{de}`
- **THEN** `ConfluxEnabled` is `0` in the same `SETCONF` as `ExitNodes`,
  before any circuit is closed
- **AND** a recovery leg tor launches for one of those sets never links
- **AND** the address the far side sees for A's next request is in Germany
  by the table the pin loaded

#### Scenario: Country data is fetched on the device, through Tor

- **GIVEN** no GeoIP table is kept on the device
- **WHEN** a site's pin is applied
- **THEN** the table is downloaded through Tor's SOCKS port on its own tag,
  never directly and never on a site's circuit
- **AND** it is stored unmodified and handed to tor as `GeoIPFile`
- **AND** the release artifact contains no GeoIP data (gated by
  `test/js/tor_geoip_not_bundled.test.js`)

#### Scenario: One bad circuit does not fail the download

- **GIVEN** no GeoIP table is kept on the device
- **AND** the onion service times out on the circuit the first request took
- **AND** the clearnet host answers the next request's exit with HTTP 403
- **WHEN** a site's pin is applied
- **THEN** the onion service is asked again on a circuit no earlier request
  took, and the table it answers is kept
- **AND** a Retry after a download that failed on every source asks each on
  circuits none of the failed requests took

#### Scenario: Missing country data fails visibly and names the data

- **GIVEN** the table cannot be downloaded, or tor will not load it
- **WHEN** a site's pin is applied
- **THEN** `ExitNodes` is not changed and the site stays blocked
- **AND** the failure is classified `exitCountryData`, whose remedy is Retry
  or clearing the pin, not picking another country
- **AND** the same pin set again by an ordinary save does not start another
  download; Retry does

---

### Requirement: TOR-015 - Every failure names itself and its remedy

Tor fails in kinds that call for opposite reactions, and the app SHALL
distinguish them rather than presenting one opaque string. A blocked
network is fixed with bridges; a wrong device clock is fixed in Settings
and by nothing else; a dead exit pin is fixed by clearing the pin; a
control-channel fault is ours and the user can do nothing about it.
Collapsing these into "Tor failed" sends the user down roads that cannot
help, which is how a working feature reads as broken.

Each classified failure SHALL carry its own heading, its own remedy text,
and its own icon, and the raw message SHALL stay visible alongside them —
the classification is pattern-matched from tor's output, and the raw line
is what makes a wrong guess obvious. The same copy SHALL back both the
status card and the in-webview interstitial, so the two cannot describe
one failure differently.

A route to bridge settings SHALL be offered only for the failure kinds
bridges can plausibly fix (`censored`, `bootstrapTimeout`).

#### Scenario: A blocked network offers bridges; a wrong clock does not

- **GIVEN** tor reports a failure classified as `censored`
- **THEN** the status card offers both Retry and a route to bridge
  settings
- **GIVEN** tor reports a failure classified as `clockSkew`
- **THEN** the card names the clock as the cause and offers Retry only

#### Scenario: The raw message survives classification

- **GIVEN** any classified failure
- **THEN** tor's own message is rendered under the classified copy
- **AND** a misclassification is therefore visible rather than hidden

#### Scenario: Retry actually restarts

- **GIVEN** a site pinned to Tor is holding the runtime and tor has failed
- **WHEN** the user presses Retry
- **THEN** the runtime is stopped and started again, keeping the holder
  set — acquiring alone returns early whenever a holder exists, so a
  Retry routed through it would be inert

---

### Requirement: TOR-016 - Bridges, configured by the user and applied at start

Where Tor itself is blocked, a bridge is the only route in, so the app
SHALL let the user configure pluggable transports: obfs4, snowflake,
meek_lite and webtunnel, run by IPtProxy.

The configuration applied at start SHALL be the persisted one, read by
the engine itself rather than pushed in by a caller. Bridges are kept in
the keystore precisely so they survive a relaunch, and nothing on a cold
start visits the settings screen: a value seeded only by that screen is
simply absent on every launch after the first, which is a bridgeless
bootstrap to the public directory authorities from the user's real IP
while the screen still shows the toggle on. A keystore that cannot be
read SHALL leave Tor startable rather than refusing to start, and SHALL
be retried on a later start rather than cached as a failure.

Bridge configuration SHALL be applied at runtime start, never by SETCONF
afterwards: bridges have to be in force before bootstrap begins, and
configuring them later means a bootstrap attempt over the direct guards
the user is trying to avoid. The transport SHALL be started first, since
its SOCKS listener port is allocated at start time and the
`ClientTransportPlugin` line is built around it.

Repeatable torrc keys SHALL survive the crossing to native code. `Bridge`
appears once per line, so the options SHALL travel as an ordered list of
pairs and reach tor through its argument vector, never through a
name-keyed map that would keep only the last line.

A transport that fails to start SHALL NOT abort the run: it yields no
bridge options, and tor comes up without bridges rather than not at all.
On a censored network that then fails at bootstrap and is reported as
`censored` (TOR-015), which is the honest outcome.

Snowflake SHALL be usable without the user supplying a line. Its
rendezvous parameters — broker URL, domain fronts, STUN servers — ride
the bridge line as SOCKS arguments and IPtProxy defaults every one of
them to empty, so the app SHALL supply the Tor Project's published
built-in snowflake line when the user has none. `UseBridges 1` with no
`Bridge` line is not a working default; it leaves tor with nothing to
dial.

Bridge lines SHALL be kept verbatim. The tail of a line is
transport-defined and tor is the authority on it, so the app validates
shape only and never re-serialises from parsed parts.

Storage is covered by TOR-017; the exposure of fetching bridges over Moat
is covered by LEAK-015.

#### Scenario: An enabled configuration reaches tor

- **GIVEN** bridges are enabled with obfs4 and two pasted lines
- **WHEN** the runtime starts
- **THEN** the transport is started and its port read back
- **AND** tor receives `UseBridges 1`, one `ClientTransportPlugin` naming
  that port, and both `Bridge` lines

#### Scenario: A persisted configuration survives a relaunch

- **GIVEN** bridges are enabled in the keystore from an earlier session
- **AND** nothing this launch has opened the bridge settings screen
- **WHEN** a site pinned to Tor starts the runtime
- **THEN** tor receives `UseBridges 1` and the stored `Bridge` lines
- **AND** the transport is started, without any caller having pushed the
  configuration in

#### Scenario: An unreadable keystore does not strand the user

- **GIVEN** the keystore throws when the bridge configuration is read
- **WHEN** the runtime starts
- **THEN** tor still starts, without bridge options
- **AND** a later start re-reads rather than reusing the failure

#### Scenario: Bridges off clear the options rather than leaving them stale

- **GIVEN** a previous start configured bridges
- **WHEN** the user turns bridges off and the runtime restarts
- **THEN** no bridge options are sent, rather than the previous set

#### Scenario: A transport that will not start does not stop tor

- **GIVEN** bridges are enabled
- **AND** starting the transport fails or reports port 0
- **THEN** no bridge options are produced
- **AND** tor still starts

#### Scenario: Snowflake with no user line still has something to dial

- **GIVEN** bridges are enabled with snowflake and no pasted lines
- **WHEN** the runtime starts
- **THEN** tor receives the built-in snowflake `Bridge` line
- **AND** that line carries its own `url=`, `fronts=` and `ice=`

#### Scenario: Only the selected transport's lines are sent

- **GIVEN** the list holds both obfs4 and snowflake lines
- **AND** snowflake is selected
- **THEN** only the snowflake lines are sent — tor rejects a `Bridge`
  line whose transport has no plugin, failing the whole configuration
  rather than ignoring it

#### Scenario: Editing bridges while tor is up says so

- **GIVEN** tor is connected
- **WHEN** the user changes the bridge configuration
- **THEN** the screen reports that a restart is needed, and offers it

---

### Requirement: TOR-017 - Bridge configuration is a secret, and never exported

A privately-allocated bridge is allocated *to a person*: it names a host
reachable from a censored network, and possessing it links its holder to
that bridge. Bridge configuration SHALL therefore live in
`flutter_secure_storage`, never in `SharedPreferences`, and SHALL NOT
appear in a settings export — the same reasoning that keeps proxy
passwords out of backups (PWD-005).

Exclusion SHALL be by construction rather than by a filter: nothing
writes bridge state to `SharedPreferences` or to `kExportedAppPrefs`, so
there is no export path to remember to suppress.

A write that did not land SHALL NOT be reported as saved: the user would
otherwise believe they are reaching Tor through a bridge that is not
configured. A keystore that cannot be read SHALL yield "bridges off",
since the alternative is telling tor `UseBridges 1` with lines the app
could not read.

Logs SHALL NOT carry bridge lines: they reach bug reports.

#### Scenario: A backup carries no bridge

- **GIVEN** bridges are configured
- **WHEN** the user exports settings
- **THEN** no bridge line, transport or enabled flag appears in the JSON

#### Scenario: A failed write is not reported as success

- **GIVEN** the keystore refuses the write
- **WHEN** the user adds a bridge line
- **THEN** the save reports failure and the UI does not claim it is set

---

### Requirement: TOR-018 - The bootstrap says which phase it is in, and tor's log is reachable

A percentage is not a diagnosis. Tor reports `TAG` and `SUMMARY` on every
`BOOTSTRAP` status event — the phase it is in, in its own words — and
without them a bootstrap that stalls looks the same as one that is merely
slow, both to the user and to the failure classifier (TOR-015), which
reads `TAG` to tell a censored network from a timeout.

The status published to Dart SHALL carry tor's `TAG` and `SUMMARY`
alongside the percentage, and the bootstrap surfaces (TOR-004, TOR-008)
SHALL render the summary beneath the progress bar whenever one is
present.

Reaching the control port SHALL be bounded by a budget a device can
meet, not by a fixed handful of attempts: tor opens its port when the
device lets it, and a cold start reading geoip on a busy phone takes
seconds. A budget of about 1.5 seconds failed runs that would have
succeeded a moment later and left an unreachable tor behind
([BUG-013](../../../../../docs/bugs/013-tor-never-connects.md)). Each
attempt SHALL re-check the run it belongs to, so a stop during the wait
costs nothing, and the wait SHALL end immediately if tor's thread exits.

On attaching to the control port the plugin SHALL read
`GETINFO status/bootstrap-phase` and publish it, because bootstrap begins
before the control port answers: without the catch-up read, a bootstrap
that finished during the handshake produces no further event and the
interstitial stays on `starting` until the timeout.

Tor's own log SHALL be readable inside the app, through Developer Tools →
App Logs:

- The runtime's state transitions SHALL be logged as ordinary entries.
- Tor's own log SHALL be captured and logged under its own tag, as
  **sensitive** entries — a notice-level line can name a bridge
  (TOR-017) — so they stay in the memory-only ring and appear only behind
  the Dev Tools toggle.
- The capture SHALL come from tor's log file (`TorConfiguration.logfile`,
  which compiles to `--Log notice file <path>`), not from the control
  port. The control port carried it first, and that fails in the one case
  that most needs explaining: a tor that never opens a control port.
  Nothing was readable on a device where that happened (BUG-013). The
  file lives in the run's data directory, is truncated at every start,
  and is removed at stop, so it does not outlive the run that wrote it;
  `SafeLogging 1` still scrubs it.
- `INFO` and `DEBUG` SHALL NOT be captured: they name every connection
  tor makes. `--Log notice` is the floor.
- The plugin SHALL also log its own lifecycle (start, control-port
  attach, authentication, SOCKS listener, transports, stop), which covers
  the window before tor's control port answers and after it goes away.

#### Scenario: The interstitial names the phase

- **GIVEN** tor is at `BOOTSTRAP PROGRESS=45 TAG=loading_descriptors
  SUMMARY="Loading relay descriptors"`
- **WHEN** a TOR-bound site is opened
- **THEN** the interstitial shows "Connecting… 45%" and the phase
  "Loading relay descriptors" beneath it

#### Scenario: A bootstrap that finished during the handshake

- **GIVEN** tor reaches 100% before the control-port handshake completes
- **WHEN** the plugin attaches
- **THEN** it reads `status/bootstrap-phase`, publishes it, and proceeds
  to read the SOCKS listener
- **AND** the interstitial does not sit on "Starting" until the timeout

#### Scenario: The waiting screen says what is happening

- **GIVEN** a TOR-bound site is opening and the runtime is not up
- **WHEN** the user looks at the interstitial
- **THEN** it renders the most recent runtime and tor log lines, live,
  beneath the progress bar
- **AND** it renders them on the failure screen too, so what led there is
  on the same screen as the failure

#### Scenario: Tor's own log is in Dev Tools

- **GIVEN** a bootstrap is under way
- **WHEN** the user opens Developer Tools → App Logs and turns on the
  sensitive-entries toggle
- **THEN** tor's `NOTICE`/`WARN`/`ERR` lines are listed under their own
  tag, alongside the runtime's state transitions
- **AND** with the toggle off, the state transitions are still listed

#### Scenario: A control port that takes its time

- **GIVEN** tor needs several seconds to open its control port
- **WHEN** the plugin attaches
- **THEN** it keeps trying for the budget rather than failing the run
- **AND** the wait is visible in the log rather than silent

#### Scenario: The log subscription is not silently dropped

- **GIVEN** the plugin has subscribed to `STATUS_CLIENT NOTICE WARN ERR`
- **WHEN** any later code path re-sends `SETEVENTS` with a narrower list
- **THEN** the structural gate
  `test/js/tor_bootstrap_observability.test.js` fails, because tor keeps
  only the most recent subscription and the log would go quiet with no
  other symptom

---

### Requirement: TOR-019 - One control connection, read before subscribing

`Tor.framework` routes command replies and asynchronous events through a
single observer list, and its `GETINFO` observer answers whatever line it
is handed first — an unrelated `650` event included, which it reports back
to its caller as an empty result and then unregisters itself.

Every control-port read the plugin needs SHALL therefore be issued before
it subscribes to events, on a connection that is still quiet, and the
values kept for later use. In particular the SOCKS endpoint SHALL be read
at attach and published when bootstrap completes, rather than read at that
moment.

Once bootstrap completes nothing observes `STATUS_CLIENT`, and the plugin
SHALL drop the subscription (`SETEVENTS` with no events) before publishing
`up`. The connection is then quiet again, and a read needed after bootstrap
(an exit-country change, TOR-014) SHALL be issued only in that window. tor's
log comes from its log file (TOR-018), so dropping the subscription takes
nothing away. `addObserver(forCircuitEstablished:)` SHALL NOT be used — it sends
its own `SETEVENTS` and follows it with a `GETINFO` that an event can
answer, after which it removes itself and `CIRCUIT_ESTABLISHED` is never
delivered again. `CIRCUIT_ESTABLISHED` SHALL be handled in the plugin's
own status observer instead.

`TORController(controlPortFile:)` opens the connection inside its own
initializer, and `connect()` answers an already-connected controller with a
bare failure carrying no error — indistinguishable from a port file that did
not parse. The plugin SHALL therefore open every control connection through
one funnel that decides on `isConnected` rather than on the throw, and SHALL
NOT call `connect()` on a controller that reports itself connected.

#### Scenario: A control port that answered is not reported as unreachable

- **GIVEN** tor has written its port file and is accepting on its control
  port
- **WHEN** the plugin opens a controller for that file
- **THEN** it treats the connection the initializer already made as the
  connection, and proceeds to authenticate
- **AND** it never reports "could not reach the control port" for a tor that
  answered

#### Scenario: A bootstrap notice does not become the SOCKS listener

- **GIVEN** tor is emitting notice-level log events
- **WHEN** bootstrap completes
- **THEN** the plugin publishes `up` with the endpoint it read at attach
- **AND** it issues no control-port read in that window, so no event can
  be mistaken for the reply

#### Scenario: A finished bootstrap is not left on the interstitial

- **GIVEN** tor establishes its first circuit
- **WHEN** the plugin's status observer sees `CIRCUIT_ESTABLISHED`, or a
  `BOOTSTRAP` event reaching 100%
- **THEN** the runtime reaches `up`
- **AND** neither path depends on a `GETINFO` completing while events are
  flowing

---

### Requirement: TOR-020 - One tor per process; a stop asks it to exit

Tor is a process singleton: `TORThread` asserts a single instance, and two
`tor_run_main`s in one address space contend for the data-directory lock,
which tor resolves by exiting the process it is linked into — taking the
app down. `NSThread.cancel()` does not stop tor, since its main loop never
reads the flag.

Stopping the runtime SHALL ask tor to exit over the control port and
SHALL hand the thread to an exit watch rather than forgetting it. The
request SHALL NOT depend on the controller the plugin adopted: a run
stopped before its handshake landed, and a run whose handshake failed,
never had one, and those are the runs most in need of stopping. The exit
watch SHALL therefore open a control connection of its own from the
retired run's port file and cookie, send `SIGNAL HALT`, and repeat while
the thread is alive, since the control port may not be open yet when the
stop lands.

A run that fails SHALL be retired on the same path: a tor nobody can
talk to must not keep the process's one slot. Starting SHALL wait for that
thread to finish, and where it does not finish within the bound SHALL fail
with a named error rather than launching a second tor. A handshake, catch-up
read or failure belonging to an earlier run SHALL be identified as such (a
generation counter bumped by every start and stop) and SHALL NOT publish
state for the current one.

**One launch, not one at a time.** A freed slot is not a fresh process.
tor's own global state outlives `tor_run_main`: the second entry reaches
`threadpool_new` with the pool already built, hits its `BUG()` and logs
"Can't create worker thread pool", and the bootstrap that follows never
progresses. The plugin SHALL therefore refuse a second launch outright,
with a named error naming the one remedy (restart the app), rather than
starting a tor that will sit at 0% until the bootstrap deadline — which
reads as "Tor could not reach the network", a failure the user retries,
burning the same dead path again.

Because the launch is spent once and for all, nothing SHALL stop the
runtime speculatively. Releasing the last holder SHALL leave tor running
(TOR-002), the bootstrap deadline SHALL report without tearing down
(TOR-013), and Retry SHALL re-arm the wait rather than stop and re-start
(TOR-005). Retry on a runtime that is already `up` SHALL do nothing at
all: the plugin's start is a no-op while tor is alive, so republishing
`starting` would strand the status there until the bootstrap deadline
reported a failure against a tor that was working. Recorded as attempt 6 in
[docs/bugs/007-native-shared-state-races.md](../../../../../docs/bugs/007-native-shared-state-races.md)
and attempt 9 in
[docs/bugs/013-tor-never-connects.md](../../../../../docs/bugs/013-tor-never-connects.md).

#### Scenario: Retry on a connected runtime changes nothing

- **GIVEN** Tor is `up` with a SOCKS listener on port P
- **WHEN** the user taps Retry, repeatedly
- **THEN** the status stays `up` and the endpoint stays P
- **AND** no bootstrap deadline is armed, so nothing later reports a
  failure against a runtime that is working

#### Scenario: A second launch is refused, not attempted

- **GIVEN** tor has already run once in this app session and its thread has
  exited
- **WHEN** something asks the runtime to start again
- **THEN** the plugin publishes an error saying Tor cannot start again in
  this session and that restarting the app makes it available
- **AND** no second `tor_run_main` is entered
- **AND** the user is not left waiting for the bootstrap deadline

#### Scenario: Retry after a failed bootstrap

- **GIVEN** bootstrap failed and the interstitial offers Retry
- **WHEN** the user taps it
- **THEN** the plugin waits for the previous tor's thread to finish before
  starting another
- **AND** the app does not terminate

#### Scenario: A stop before the control port answered

- **GIVEN** the runtime is stopped while its control-port handshake is
  still in flight
- **WHEN** the handshake completes
- **THEN** it is recognised as belonging to a previous run, and the
  controller is disconnected rather than adopted
- **AND** the exit watch asks that tor to quit over its own connection,
  so the slot is free whether or not the handshake ever completed

#### Scenario: Retry after a run that never reached its control port

- **GIVEN** a run failed because its control port could not be reached
- **WHEN** the user taps Retry
- **THEN** the failed run has already been retired and asked to quit
- **AND** the new run starts rather than reporting that the previous Tor
  is still running

---

### Requirement: TOR-021 - The runtime is exercised by an integration tier

Every other Tor test drives a fake `TorRuntime`, which cannot fail the
way the real one does: TOR-019 and TOR-020 were both defects in the
conversation with tor, and both shipped. The system SHALL therefore
carry an integration scenario that runs against the real plugin.

It runs on macOS, because iOS has no integration tier here and macOS
reuses the same harness natively (INTEG-009). The plugin source is
shared (`ios/Runner/TorControllerPlugin.swift`, compiled by both Apple
targets) rather than copied, so what the tier exercises is what iOS
ships.

The scenario SHALL assert, without depending on the Tor network:

- the control-port handshake completes and the runtime leaves
  `starting`,
- a `bootstrapping` status carries tor's own phase (TOR-018),
- tor's own log lines reach `LogService` under their own tag,
- a restart returns the runtime to a live state rather than taking the
  process down (TOR-020).

Reaching `up` needs the network to permit tor, so the scenario SHALL
require it only where the run opted in (`WEBSPACE_TOR_NETWORK=1`, which
the CI step sets) and SHALL otherwise degrade to a skip carrying the
captured log. That relaxation covers the network and nothing else: a
failure classified `controlChannel` SHALL fail the scenario on every run,
since no part of reaching tor's own control port depends on the network.

#### Scenario: The tier runs the real handshake

- **GIVEN** a macOS build whose pods carry tor
- **WHEN** the integration scenario starts the runtime
- **THEN** it observes a bootstrap phase, tor's log, and a successful
  restart
- **AND** a failure names what tor said rather than a timeout

#### Scenario: A broken handshake is not recorded as a missing network

- **GIVEN** a run that did not opt into the Tor network
- **WHEN** the runtime ends in a `controlChannel` failure
- **THEN** the scenario fails carrying the transcript, rather than skipping

#### Scenario: A build with no plugin behind the channels fails loudly

- **GIVEN** a build where the plugin did not register
- **WHEN** the scenario runs
- **THEN** it fails naming the missing runtime, rather than passing on a
  runtime that was never there

---

### Requirement: TOR-022 - A gate that cannot open SHALL say so

TOR-013 requires that a bootstrap resolve to progress or an error. There
is a third outcome it does not cover: the runtime that never starts at
all. `TorService.maybeStart` returns at the TOR-007 gate before
`TorEngine.acquire` emits `TorStarting`, so the status stays `stopped`
and the interstitial renders the same screen it shows while waiting --
an indeterminate bar under "Not running", with no Retry (that button
lives in the failure branch) and nothing naming what would fix it. It is
the unbounded spinner TOR-013 exists to forbid, arrived at from the other
side, and it is reachable: the per-site dropdown keeps `TOR` selectable
on a site that already carries it, so a configuration imported from an
Apple device (settings backup, site QR) leaves an Android or Linux site
pinned to a runtime that platform does not have.

The interstitial SHALL distinguish these, and the decision SHALL be a
pure function of (status, platform capability) rather than of the status
alone:

- **working** - Tor can come up here and is on its way. The progress bar
  means something.
- **errored** - tor failed. Retry, and bridges where they help.
- **unsupported** - this build has no Tor. The screen SHALL say so and
  SHALL name the site's own proxy setting as the thing to change.

Availability SHALL be read before the status. An errored status on a
platform with no runtime SHALL render as unsupported rather than as a
failure, because `restart()` returns at the same gate and a Retry button
there does nothing.

The site SHALL stay blocked in every one of these states: naming a
missing runtime is a change to what the user is told, never to what
TOR-008 permits on the wire.

#### Scenario: A Tor site on a platform with no Tor

- **GIVEN** a site carrying `ProxyType.TOR`, imported onto Android
- **WHEN** the user opens it
- **THEN** the interstitial says Tor is not available on this device
- **AND** it names the site's proxy setting as what to change
- **AND** no progress bar is shown
- **AND** the site is not loaded over the device IP

#### Scenario: A Tor site with developer mode off

- **GIVEN** an iOS build with developer mode off and a site set to `TOR`
- **WHEN** the user opens it
- **THEN** the interstitial shows Tor's progress, as with developer mode on

---

### Requirement: TOR-024 - Tor outlives the app being suspended

iOS suspends an app it has sent to the background, and while it is
suspended the kernel defuncts every socket the app owns that is not marked
non-defunctable: `socket_defunct` passes `noforce`, and every Unix-domain
socket is born SOF_NODEFUNCT while a TCP socket can only be marked by root
(xnu `socreate`, `sosetdefunct`, `SO_DEFUNCTOK`). tor itself survives,
frozen with the app, but a loopback TCP control port, its SOCKS listener
and its relay connections do not, and tor goes on naming the dead listener
as its own. Since tor runs once per process (TOR-020), a runtime nobody can
reach again is Tor gone until the app restarts, which is how it was first
reported: a background launch started tor, iOS suspended the app, and the
next foreground found "The previous Tor is still running".

- The plugin's control channel SHALL be a Unix-domain socket (`ControlSocket`)
  in a directory only the app's user can list, whose path fits a
  `sockaddr_un`. Where it would not fit, the plugin SHALL fall back to a TCP
  control port and SHALL say in the log that it will not survive a
  suspension.
- When the app returns to the foreground, and at the start of a background
  wake, the engine SHALL ask tor's SOCKS listener for a SOCKS5 greeting. A
  listener that does not answer SHALL be reopened over the control channel
  (`DisableNetwork 1`, then `0`, which closes every listener and relay
  connection except control ones and opens the listeners again), and the new
  endpoint SHALL be published as `up`, which rebinds every Tor-bound site.
  While that happens the engine SHALL hold the sites off Tor, as a pin change
  does.
- A return while tor is still bootstrapping SHALL have the listener asked
  when tor next reports `up`, before anything is bound to it.
- A reopen that fails SHALL be reported as a failure, never as the dead
  listener being `up`, and Retry SHALL try the reopen again.
- An exit-country pin in force SHALL stay in force across a reopen: it is
  the same tor, and nothing re-applies it.
- The bootstrap deadline (TOR-013) SHALL NOT report a bootstrap the app was
  suspended through. A deadline that fires more than a few seconds after it
  was due SHALL start its window over.

#### Scenario: The app comes back after tor's sockets were defuncted

- **GIVEN** Tor is up and a site is bound to its SOCKS listener
- **AND** the process's sockets have been defuncted, as iOS does to a
  suspended app
- **WHEN** the app returns to the foreground
- **THEN** tor's control channel still answers
- **AND** tor opens a new SOCKS listener and the runtime publishes it as `up`
- **AND** a request through it leaves from a Tor exit

#### Scenario: A listener that still answers is left alone

- **GIVEN** Tor is up
- **WHEN** the app returns to the foreground without having been suspended
- **THEN** the listener answers the greeting and nothing is reopened

#### Scenario: The app comes back mid-bootstrap

- **GIVEN** the app was suspended while tor was bootstrapping
- **WHEN** the app returns and tor then reports `up` on a listener opened
  before the suspension
- **THEN** that listener is asked before any site is bound to it
- **AND** a dead one is reopened and never published as `up`

#### Scenario: The deadline slept through a suspension

- **GIVEN** tor was started and the app was suspended before it finished
  bootstrapping
- **WHEN** the bootstrap deadline fires on the next wake, long after it was due
- **THEN** no bootstrap failure is reported and the window starts over
