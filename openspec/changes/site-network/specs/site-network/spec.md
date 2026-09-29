# Site Network

## ADDED Requirements

### Requirement: NET-001 — Network screen

Everything that decides how a site's traffic reaches the internet SHALL live on
one per-site Network screen (`SiteNetworkScreen`), reached from a single row in
site settings. None of its controls SHALL remain on the settings screen.

The screen SHALL present, in order: a "Proxy" group holding the shared-proxy
note, the proxy type (with its LEAK-010 coverage caption), the Tor exit country
while the type is TOR (TOR-014), the address field and the credentials fold
while the type is HTTP, HTTPS or SOCKS5 (PROXY-010, PROXY-019), and the
connection test while any proxy is chosen; then a "Connection" group holding
the WebRTC policy and, except for archive-tier sites (HTTPAUTH-004), the saved
sign-ins row. While Tracking Protection is on and the site is proxied, the
WebRTC row shows the ETP-031 floor: Default disabled, its value raised to
Relay only, and a caption saying why. The screen reads the unsaved umbrella
value and whether an app-wide proxy is set from its caller. The "Proxy" group SHALL be absent where the platform cannot bind
a per-site proxy (PROXY-006); the "Connection" group is always shown.

The screen SHALL own no persistent state. `SettingsScreen` keeps the fields,
the dirty-snapshot diff and the save path (BUG-006 / EDIT-009); the screen
reads a `SiteNetworkValues` (proxy type, Tor exit country, WebRTC policy) and
reports whole values back through `onChanged`. The proxy address, username and
password are text and SHALL be edited in controllers the caller owns, since
those are what its snapshot reads. The connection test SHALL be built by the
caller, which owns the save path and so knows what a save would store
(PROXY-019). Forgetting saved sign-ins acts at once, as it did inline: it is
not a setting the user can take back by discarding the form.

#### Scenario: Every network control is on the screen

**Given** the user opens the per-site Network screen on a platform that binds
per-site proxies
**Then** the proxy type and WebRTC policy dropdowns are shown under "Proxy"
and "Connection"
**And** the settings screen it was reached from shows neither dropdown nor the
saved sign-ins row

#### Scenario: No proxy group where none can bind

**Given** the platform cannot bind a per-site proxy
**When** the Network screen opens
**Then** no "Proxy" heading and no proxy type dropdown is shown
**And** the WebRTC policy is

#### Scenario: A pick reports the whole value

**Given** a site with WebRTC set to Relay only
**When** the user picks SOCKS5 as the proxy type
**Then** `onChanged` receives SOCKS5 together with Relay only
**And** the address field and the credentials fold appear

#### Scenario: TOR hides the manual fields

**Given** the proxy type is TOR
**Then** the address field and credentials fold are not shown
**And** the exit country row is, reading the pinned country or "Any country"

#### Scenario: An edit survives until the settings screen saves it

**Given** the user changes the WebRTC policy, or pins a Tor exit country, on
the Network screen and goes back
**Then** the settings screen's snapshot diff sees the change
**And** leaving site settings without saving prompts to discard it

### Requirement: NET-002 — Settings row summarises without opening

The Network row SHALL sit under the "Site" heading, second, between Behaviour
and Privacy (BEHAV-002).

The row SHALL answer whether and how the site is proxied without being opened,
from the unsaved form: the site's own proxy as its type and address (TOR as
its type, followed by the pinned exit country when there is one; a saved proxy
by its name, or as missing when it no longer exists, PROXY-029); "App-wide
proxy" when the site sets no proxy of its own and the app-wide outbound proxy
is set, since such a site goes through it; and "WebRTC: {policy}" when the
WebRTC policy the site will run is not the default, which counts a Default
that Tracking Protection raises to Relay only behind a proxy (ETP-031). At
most two entries SHALL be named, followed
by a "{count} more" overflow. With none of these, the row SHALL read "Default
connection". Proxy entries SHALL appear only where the platform binds a
per-site proxy.

#### Scenario: Nothing set

**Given** a site with no proxy, no app-wide proxy and the default WebRTC policy
**Then** the Network row reads "Default connection"

#### Scenario: Inherited proxy

**Given** a site with no proxy of its own and Tracking Protection off
**And** an app-wide outbound proxy is set in App Settings
**Then** the Network row reads "App-wide proxy"

#### Scenario: Inherited proxy under Tracking Protection

**Given** a site with no proxy of its own, Tracking Protection on and the
default WebRTC policy
**And** an app-wide outbound proxy is set in App Settings
**Then** the Network row reads "App-wide proxy · WebRTC: Relay only"

#### Scenario: The site's own proxy

**Given** a site on SOCKS5 `127.0.0.1:1080` with WebRTC set to Relay only
**Then** the Network row reads "SOCKS5 127.0.0.1:1080 · WebRTC: Relay only"

#### Scenario: More than two overflow

**Given** a site on TOR pinned to an exit country, with WebRTC disabled
**Then** the row names TOR and the country, then "1 more"

#### Scenario: A saved proxy by name

**Given** a site that names the saved proxy "Work VPN"
**Then** the Network row reads "Work VPN"

### Requirement: NET-003 — The address is checked where it is typed

The proxy address field SHALL validate as the user edits it, with the rule the
save path runs (`validateProxyAddress`): required and `host:port` with a port
in 1–65535 for HTTP, HTTPS and SOCKS5; nothing to check for DEFAULT and TOR
(TOR-007). The save path SHALL keep running the same rule, since the field is
not shown again once the user has left the Network screen.

#### Scenario: A malformed address is flagged on the screen

**Given** the proxy type is SOCKS5
**When** the user types `proxy.example.com` into the address field
**Then** the field shows "Format should be host:port"
**And** the error clears once the address reads `proxy.example.com:1080`
