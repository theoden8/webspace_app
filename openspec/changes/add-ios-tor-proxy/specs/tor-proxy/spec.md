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
count of per-site `useTor=true` entries plus 1 if `globalOutboundProxy.type == TOR`).
When the refcount transitions from 0 to >0 the runtime SHALL start;
when it transitions from >0 to 0 a 60-second debounce timer SHALL
start, and the runtime SHALL stop only when the timer fires with the
refcount still at 0. Reactivation during the debounce SHALL cancel
the timer and keep the runtime up.

#### Scenario: First useTor site starts Tor

- **GIVEN** the app is running with no `useTor` sites and
  `globalOutboundProxy.type != TOR`
- **AND** `TorService.status` is `stopped`
- **WHEN** the user enables `useTor` on a site and saves
- **THEN** `TorService.status` transitions to `starting`, then
  `bootstrapping(_)`, then `up`
- **AND** the SOCKS5 endpoint becomes available to webview and
  Dart-side callers

#### Scenario: Disabling last useTor site debounces shutdown

- **GIVEN** exactly one site has `useTor=true` and Tor is `up`
- **WHEN** the user disables `useTor` on that site
- **THEN** `TorService` schedules a 60-second debounce timer
- **AND** the runtime remains `up` during the debounce
- **AND** when the timer fires with no refcount, the runtime stops

#### Scenario: Reactivation cancels debounce

- **GIVEN** the debounce timer is running with 30 seconds remaining
- **WHEN** the user enables `useTor` on another site
- **THEN** the timer is canceled
- **AND** `TorService.status` stays `up` with no new bootstrap
  cycle

---

### Requirement: TOR-003 - Per-site stream isolation via SOCKS auth

`TorService.socksFor` SHALL materialize SOCKS5 settings whose username is the requesting site's `siteId` (or the reserved literal `__webspace_app_global__` for app-global Dart-side traffic) and whose password is a per-app-launch random secret. Tor SHALL be configured with `SocksPort … IsolateSOCKSAuth IsolateDestAddr` so distinct username/password tuples force distinct circuits.

#### Scenario: Two useTor sites get distinct exit IPs

- **GIVEN** site A (`siteId = a1`) and site B (`siteId = b2`) both
  have `useTor=true`
- **WHEN** both sites are loaded concurrently in container mode and
  each fetches `https://check.torproject.org/`
- **THEN** the JSON response shows two distinct exit IP addresses
- **AND** the response for site A and site B never share a circuit
  identifier (verified via Tor control port `GETINFO circuit-status`)

#### Scenario: App-global traffic isolates from per-site

- **GIVEN** the global outbound proxy is `TOR` and site A has
  `useTor=true`
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
show a small inline indicator next to the `useTor` switch when
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

- **GIVEN** Tor is `up` and a `useTor` site's last
  `https://check.torproject.org/` response showed exit IP X
- **WHEN** the user taps "Rebuild circuits"
- **AND** the same site re-fetches `https://check.torproject.org/`
- **THEN** the response shows an exit IP different from X within 10
  seconds (probabilistically — Tor may very rarely re-select the
  same node; tests retry once)

#### Scenario: Rebuild does not interrupt non-Tor sites

- **GIVEN** site A has `useTor=true` and site B has `useTor=false`
- **WHEN** the user taps "Rebuild circuits" while both sites are
  loaded
- **THEN** site B's connection is unaffected
- **AND** site A's next request opens a new circuit

---

### Requirement: TOR-006 - Background grace window integration

`BackgroundTaskService` SHALL keep `TorService` running through its ~30-second `beginBackgroundTask` grace window on iOS app pause if at least one notification site has `useTor=true`, and the `BGAppRefreshTask` registered for notification sites SHALL pre-warm Tor (call `maybeStart` and await `up`) before reloading any `useTor` notification site so the reload does not cold-bootstrap.

#### Scenario: Notification + Tor site keeps Tor alive during pause

- **GIVEN** site N has `notificationsEnabled=true` and `useTor=true`
- **WHEN** the app moves to background
- **THEN** `BackgroundTaskService.beginBackgroundTask` is invoked
- **AND** `TorService` does not enter the idle-stop debounce while
  the grace window is open
- **AND** notifications from site N continue to be delivered through
  Tor

#### Scenario: BGAppRefreshTask pre-warms Tor

- **GIVEN** site N has `notificationsEnabled=true` and `useTor=true`
- **AND** the OS dispatches `BGAppRefreshTask`
- **WHEN** the task handler runs
- **THEN** `TorService.maybeStart` is awaited until `up` (or fails)
- **AND** only then does the handler trigger site N's reload

---

### Requirement: TOR-007 - Platform gate

`TorService` SHALL only operate on iOS in the first cut. On every
other platform `TorService.isAvailable` SHALL return `false`, and
the per-site `useTor` switch SHALL be hidden in the UI. Existing
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

The system SHALL fail closed when a `useTor` request originates while `TorService.status != up`: Dart-side seams via `outboundHttp.clientFor` MUST return `OutboundClientBlocked` (never falling back to a direct connection), and webview navigation MUST be intercepted and rewritten to a Flutter-rendered bootstrap interstitial (`webspace://tor-bootstrap?next=<encoded>`) which auto-resumes navigation once `up`.

#### Scenario: Pre-bootstrap favicon fetch fails closed

- **GIVEN** site A has `useTor=true` and `TorService.status == bootstrapping(20)`
- **WHEN** the favicon stream runs for site A
- **THEN** `outboundHttp.clientFor(useTor)` returns
  `OutboundClientBlocked`
- **AND** no TCP socket is opened to any host
- **AND** the favicon falls back to the cached/default favicon
  rather than fetching directly

#### Scenario: Pre-bootstrap webview navigation shows interstitial

- **GIVEN** site A has `useTor=true` and `TorService.status == starting`
- **WHEN** the user activates site A
- **THEN** the WebView loads
  `webspace://tor-bootstrap?next=<original-url>`
- **AND** a progress bar bound to `TorService.statusStream` renders
- **AND** when status reaches `up`, the WebView navigates to the
  original URL automatically

#### Scenario: Error state surfaces, never falls through

- **GIVEN** `TorService.status == error("…")`
- **WHEN** any `useTor` request originates
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

- **GIVEN** Tor is `up` and at least one `useTor` site exists
- **WHEN** the user exports settings via Settings → Backup
- **THEN** the resulting JSON contains no Tor control-cookie bytes
- **AND** the JSON contains no SOCKS5 password material
- **AND** the regression test
  `test/settings_backup_test.dart::Tor secrets never appear in
  exports` asserts neither the cookie nor the session secret string
  appears anywhere in the serialized output
