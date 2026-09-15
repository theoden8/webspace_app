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

### Requirement: TOR-007 - Platform and developer-mode gate

`TorService` SHALL operate on iOS and macOS, **and only while
developer mode is on**. `TorService.isAvailable` SHALL be the
conjunction of the two, and SHALL be the single reader both the
per-site and app-global proxy-type dropdowns consult; with it false the
`TOR` option SHALL be absent from both. Existing per-site SOCKS5
configuration (manual `host:port`, with or without credentials) SHALL
remain available on every platform that supports proxies today, so
Android users can still point at Orbot's SOCKS5 endpoint manually.

**Why developer mode and not release.** The bootstrap interstitial and
status card (TOR-004/TOR-008/TOR-013) are not built. Without them a
site set to `TOR` sits on the fail-closed blank page for the length of
a bootstrap with nothing on screen explaining why, which is a support
burden and a Guideline 2.1 completeness risk. Reusing DEVTOOLS-010
rather than adding a second flag keeps one answer to "is this feature
reachable", and it is deliberately reachable on release builds: the
users who can exercise an embedded tor on real hardware are the ones
who would report on it, and a debug-build gate would exclude them.
This gate comes off when TOR-013's surface lands, not when the code
merges.

**Where the gate lives.** On `TorService`, not on
`MethodChannelTorRuntime` or `TorEngine`. Those answer the narrower
question "does this build have a tor to talk to" and are unit-tested
against a fake on that basis; folding a user-facing flag into them
would conflate capability with permission. Every start path on
`TorService` SHALL re-check the gate, so the answer does not depend on
a caller having asked first, and `socksFor` SHALL return null with the
gate shut — a site still carrying `ProxyType.TOR` from before the flag
was turned off is blocked, never quietly sent out over the device IP.

Turning developer mode off SHALL release the refcount holders already
taken rather than leave the runtime pinned up for a feature the user
can no longer reach.

**macOS carries it on the same terms as iOS.** It is behind developer
mode, it is not a promoted feature, and it is the platform whose
integration tier can run the real control-port handshake (TOR-021).
Both platforms SHALL pin the same pod versions: a skew would mean the
tier tests something other than what iOS ships.

The macOS floor moves with the pod. `Tor` is a macOS 11 pod, so
`platform :osx`, `MACOSX_DEPLOYMENT_TARGET` and the
`LSMinimumSystemVersion` that derives from it are 11.0, and macOS 10.15
is no longer a supported floor — state it in the listing
([docs/releasing-macos.md](../../../../../docs/releasing-macos.md)).

#### Scenario: Tor is absent until developer mode is on

- **GIVEN** the app is running on iOS with developer mode off
- **WHEN** the user opens a site's Proxy settings block
- **THEN** `TOR` is absent from the proxy-type dropdown
- **AND** turning developer mode on makes it available with no restart

#### Scenario: Turning developer mode off stops the runtime

- **GIVEN** a site is routed through Tor and the runtime is up
- **WHEN** the user turns developer mode off
- **THEN** the holders are released and the runtime is allowed to stop
- **AND** that site's requests are blocked rather than sent direct

#### Scenario: Android hides the Tor switch

- **GIVEN** the app is running on Android
- **WHEN** the user opens a site's Proxy settings block
- **THEN** the "Route through Tor" switch is not rendered
- **AND** the manual proxy fields are rendered as before

#### Scenario: macOS hides the Tor switch until developer mode is on

- **GIVEN** the app is running on macOS with developer mode off
- **WHEN** the user opens a site's Proxy settings block
- **THEN** the "Route through Tor" switch is not rendered
- **AND** turning developer mode on makes it available, as on iOS

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
is covered by LEAK-010.

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

On attaching to the control port the plugin SHALL read
`GETINFO status/bootstrap-phase` and publish it, because bootstrap begins
before the control port answers: without the catch-up read, a bootstrap
that finished during the handshake produces no further event and the
interstitial stays on `starting` until the timeout.

Tor's own log SHALL be readable inside the app, through Developer Tools →
App Logs:

- The runtime's state transitions SHALL be logged as ordinary entries.
- Tor's `NOTICE`, `WARN` and `ERR` output SHALL be captured over the
  control port and logged under its own tag, as **sensitive** entries — a
  notice-level line can name a bridge (TOR-017) — so they stay in the
  memory-only ring and appear only behind the Dev Tools toggle.
- `INFO` and `DEBUG` SHALL NOT be subscribed to: they name every
  connection tor makes.
- Tor's log SHALL NOT be written to a file. The control port is the
  capture surface precisely so nothing outlives the session on disk
  (`TorConfiguration.logfile` unset; the `Log` line stays pointed at
  `/dev/null`).
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

#### Scenario: Tor's own log is in Dev Tools

- **GIVEN** a bootstrap is under way
- **WHEN** the user opens Developer Tools → App Logs and turns on the
  sensitive-entries toggle
- **THEN** tor's `NOTICE`/`WARN`/`ERR` lines are listed under their own
  tag, alongside the runtime's state transitions
- **AND** with the toggle off, the state transitions are still listed

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

After subscribing, nothing SHALL send `SETEVENTS` again: tor keeps only
the most recent subscription, so a narrower list silently takes tor's log
away. `addObserver(forCircuitEstablished:)` SHALL NOT be used — it sends
its own `SETEVENTS` and follows it with a `GETINFO` that an event can
answer, after which it removes itself and `CIRCUIT_ESTABLISHED` is never
delivered again. `CIRCUIT_ESTABLISHED` SHALL be handled in the plugin's
own status observer instead.

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

Stopping the runtime SHALL ask tor to exit over the control port
(`disconnect()` sends `SIGNAL SHUTDOWN`, which a client tor obeys
immediately) and SHALL hand the thread to an exit watch rather than
forgetting it. Starting SHALL wait for that thread to finish, and where it
does not finish within the bound SHALL fail with a named error rather than
launching a second tor. A handshake, catch-up read or failure belonging to
an earlier run SHALL be identified as such (a generation counter bumped by
every start and stop) and SHALL NOT publish state for the current one.

Restart, the idle stop, and the bootstrap timeout all put a stop and a
start within seconds of each other, so this is the common path, not an
edge case. Recorded as attempt 6 in
[docs/bugs/007-native-shared-state-races.md](../../../../../docs/bugs/007-native-shared-state-races.md).

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
- **AND** that disconnect is what asks the orphaned tor to exit

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
captured log.

#### Scenario: The tier runs the real handshake

- **GIVEN** a macOS build whose pods carry tor
- **WHEN** the integration scenario starts the runtime
- **THEN** it observes a bootstrap phase, tor's log, and a successful
  restart
- **AND** a failure names what tor said rather than a timeout

#### Scenario: A build with no plugin behind the channels fails loudly

- **GIVEN** a build where the plugin did not register
- **WHEN** the scenario runs
- **THEN** it fails naming the missing runtime, rather than passing on a
  runtime that was never there
