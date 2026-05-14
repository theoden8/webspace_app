## ADDED Requirements

### Requirement: LEAK-008 - Tor stream isolation contract

The system SHALL route per-site `useTor` traffic and `globalOutboundProxy.type == TOR` traffic through the embedded Tor runtime's SOCKS5 endpoint, using a SOCKS5 username that gives Tor's `IsolateSOCKSAuth IsolateDestAddr` semantics a stable per-context isolation tag: per-site traffic MUST use the site's `siteId`, app-global traffic MUST use the reserved literal `__webspace_app_global__`, and the system MUST NOT share a single SOCKS username across distinct sites or re-use a site's username for app-global traffic.

#### Scenario: Two useTor sites get uncorrelatable circuits

**Given** sites A (`siteId = a`) and B (`siteId = b`) both have
`useTor = true` and are loaded concurrently
**When** each fetches the same Tor-circuit fingerprinting endpoint
**Then** the fetches use distinct Tor circuits
**And** an observer at the destination cannot link the two fetches
to the same Tor client

#### Scenario: Per-site useTor wins over inherited global TOR

**Given** `globalOutboundProxy.type == TOR`
**And** site A has `useTor = true`
**When** site A initiates a Dart-side outbound call
**Then** `resolveEffectiveProxy` resolves to per-site TOR with
SOCKS username = `a` (not `__webspace_app_global__`)

#### Scenario: Pre-bootstrap traffic fails closed

**Given** `TorService.status == bootstrapping(30)`
**And** site A has `useTor = true`
**When** site A's user-script handler issues `__ws_f_*`
**Then** `outboundHttp.clientFor(useTorSettings)` returns
`OutboundClientBlocked`
**And** the user script's outbound call resolves with the
fail-closed sentinel
**And** no TCP socket is opened directly to the destination

---

### Requirement: LEAK-009 - Tor control port is loopback-only

The Tor control port used by `TorService` SHALL bind to loopback
only and SHALL use cookie authentication (Tor.framework's default).
The cookie file SHALL live inside the app sandbox container, SHALL
NOT be exposed via any Flutter method channel, and SHALL NOT
participate in settings backup. No Dart code SHALL talk directly to
the control port — every command (`SIGNAL NEWNYM`, `GETINFO …`) goes
through the Swift plugin, which validates and forwards.

#### Scenario: Control port traffic never leaves the device

**Given** Tor is `up`
**When** the OS-level network observer (`nettop` on macOS over a
USB-tethered iOS device, or equivalent) is checked for the control
port
**Then** all activity on the control port is between
`127.0.0.1:<random-control-port>` and `127.0.0.1:<random-client>`
**And** no external network endpoint is bound

#### Scenario: Control cookie is not exported

**Given** the user exports settings to a backup file
**When** the backup JSON is inspected
**Then** no Tor control-cookie byte sequence appears anywhere in
the file
**And** the regression test
`test/settings_backup_test.dart::Tor secrets never appear in exports`
asserts this property

---

## MODIFIED Requirements

### Requirement: LEAK-007 - Coverage matrix

The proxy-coverage matrix below SHALL be kept in sync with the
implementation. Adding a new outbound seam without registering it
here is a spec violation. The Tor runtime introduces three
additional categories: per-site `useTor` traffic, app-global TOR
traffic, and the Tor control port itself (loopback-only).

| Category | Trigger | Proxy applied | Implementation |
|---|---|---|---|
| Webview navigation (HTTP/HTTPS/CONNECT) | Site load, in-page request | Per-site (DEFAULT → global) | `ProxyManager.setProxySettings`, `lib/services/webview.dart` |
| Webview WebRTC | RTCPeerConnection / STUN | Per-site `webRtcPolicy` | `lib/services/location_spoof_service.dart` |
| Favicon: DDG, Google, FaviconFinder, SVG body | `getFaviconUrl(Stream)`, `getSvgContent`, `FaviconFinder.getAll` | Per-site (DEFAULT → global) | `lib/services/icon_service.dart`, `lib/third_party/favicon/favicon.dart` |
| Per-site downloads (HTTP/HTTPS) | `onDownloadStartRequest` | Per-site (DEFAULT → global) | `DownloadEngine`, `lib/services/webview.dart:_handleHttpDownload` |
| User-script remote fetches | `__ws_s_*` / `__ws_f_*` JS handlers | Per-site (DEFAULT → global) | `lib/services/user_script_service.dart` |
| OSM tile fetches | Location-picker "Load map" | Global only | `lib/screens/location_picker.dart` |
| ClearURLs rules download | "Update ClearURLs rules" | Global only | `ClearUrlService.downloadRules` |
| DNS blocklist download | "Update DNS blocklist" | Global only | `DnsBlockService.downloadList` |
| Content-blocker list download | "Update content-blocker list" | Global only | `ContentBlockerService.downloadList` |
| LocalCDN catalog download | LocalCDN cache populate | Global only | `LocalCdnService._downloadAndCache` |
| Per-site Tor traffic (any of the above with `useTor=true`) | Same triggers as above | Tor SOCKS5 via `TorService.socksFor(siteId)` | `lib/services/tor_service.dart`, `lib/services/outbound_http.dart` (Tor branch), `lib/services/webview.dart` (`_userProxyToInappProxy` Tor branch) |
| App-global Tor traffic (any "Global only" row with `globalOutboundProxy == TOR`) | Same triggers as above | Tor SOCKS5 via `TorService.socksFor("__webspace_app_global__")` | `lib/services/tor_service.dart`, `lib/services/outbound_http.dart` (Tor branch) |
| Tor control port | Internal: bootstrap progress, `SIGNAL NEWNYM`, `GETINFO` | Loopback-only, no external traffic | `ios/Runner/TorControllerPlugin.swift` |

#### Scenario: New outbound code path

**Given** a developer adds a new Dart-side `http.get(...)` somewhere in `lib/`
**Then** the code review process SHALL fail until either:
  - the call is rerouted through `outboundHttp.clientFor(...)` with the
    appropriate per-site or global proxy (which naturally picks up
    Tor when applicable), **or**
  - the spec's coverage matrix gains a row justifying why the call is
    exempt (e.g. localhost-only, app-bundle resource fetch)

#### Scenario: New Tor-routed outbound code path

**Given** a developer adds a new outbound seam that needs to honor
`useTor` and/or `globalOutboundProxy == TOR`
**Then** the code review process SHALL fail until the seam threads
its `UserProxySettings` through `outboundHttp.clientFor` (which
handles the Tor branch centrally)
**And** the new seam appears in this coverage matrix under either
"Per-site Tor traffic" or "App-global Tor traffic"
