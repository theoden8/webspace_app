# Proxy Feature Specification

## Purpose

The proxy feature allows users to configure HTTP, HTTPS, and SOCKS5 proxies
for their web views on supported platforms. Three delivery paths coexist:

- **Android** — process-wide override via `inapp.ProxyController` (a
  WebView singleton). Per-site values live in the data model;
  activating a site disposes any other loaded site whose effective
  proxy differs before the global override flips, so per-site routing
  is honored at the cost of cold-starting mismatched sites on switch.
- **Linux** — global override via `inapp.ProxyController`. The fork's
  `flutter_inappwebview_linux` ProxyManager fans the override out
  across the default `WebKitNetworkSession` AND every cached
  container session (one per `siteId`), so a contained site honors
  the global proxy too. Per-site is still last-write-wins (no per-site
  proxy primitive on Linux), but contained sites no longer silently
  bypass it.
- **iOS 17+ / macOS 14+** — true concurrent per-site override via
  `WKWebsiteDataStore.proxyConfigurations`, set on the per-site data store
  created by the WebSpace fork's `preWKWebViewConfiguration` hook
  (resolved via `dependency_overrides` in
  [`pubspec.yaml`](../../../pubspec.yaml)).

The Android serialisation vs. iOS/macOS concurrency difference is
observable to the user; see
[PROXY-008](#requirement-proxy-008---android--ios-concurrency-asymmetry).

The integrity contract for which traffic actually flows through the
configured proxy — per-site vs. app-global, fail-closed-on-SOCKS5 from
Dart, WebRTC lockdown, DNS leak posture — lives in
[`openspec/specs/ip-leakage/spec.md`](../ip-leakage/spec.md). Any code
that adds a new outbound seam MUST be reflected there.

## Status

- **Status**: Completed
- **Platforms**: Android (per-site via serialised global override),
  iOS 17+ / macOS 14+ (concurrent per-site),
  Linux (global override via WebKitNetworkSession);
  Windows (system default — UI hidden).

---

## Requirements

### Requirement: PROXY-001 - Supported Proxy Types

The system SHALL support the following proxy types:

1. **DEFAULT** - Use system proxy settings (no override)
2. **HTTP** - HTTP proxy protocol
3. **HTTPS** - HTTPS proxy protocol (HTTP CONNECT over TLS to the proxy)
4. **SOCKS5** - SOCKS5 proxy protocol (ideal for Tor, SSH tunnels, etc.)

#### Scenario: Select HTTP proxy type

**Given** the user is on the settings screen for a site
**When** the user selects "HTTP" from the Proxy Type dropdown
**And** enters "proxy.example.com:8080" as the address
**And** saves settings
**Then** the site uses the HTTP proxy for all requests

---

### Requirement: PROXY-002 - Per-Webview Proxy Configuration

Each webview SHALL have its own proxy configuration in the data model
(`WebViewModel.proxySettings`). The configuration is persisted per site and
restored on app restart.

#### Scenario: Configure different proxies per site (iOS / macOS)

**Given** Site A and Site B exist on iOS 17+ / macOS 14+
**And** Site A and Site B share a base domain (so both can be loaded
concurrently under [container mode](../per-site-containers/spec.md))
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** Site A routes traffic through the SOCKS5 proxy
**And** Site B routes traffic through the HTTP proxy at the same time

#### Scenario: Configure different proxies per site (Android)

**Given** Site A and Site B exist on Android
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** the data model stores both per-site values independently
**And** activating a site disposes any other loaded site whose effective
proxy differs before the global override flips (see PROXY-008 for the
underlying API constraint)

---

### Requirement: PROXY-003 - Runtime Proxy Switching

Users SHALL be able to change proxy settings without restarting the app.

#### Scenario: Change proxy at runtime (Android)

**Given** a site is currently using DEFAULT proxy on Android
**When** the user changes to SOCKS5 proxy "localhost:9050"
**And** saves settings
**Then** the proxy change takes effect on the next request via
`ProxyController.setProxyOverride`
**And** no app restart is required

#### Scenario: Change proxy at runtime (iOS / macOS)

**Given** a site is currently using DEFAULT proxy on iOS 17+ / macOS 14+
**When** the user changes to SOCKS5 proxy "localhost:9050"
**And** saves settings
**Then** the live `WKWebView` is discarded by
`WebViewModel.updateProxySettings` (which calls `disposeWebView`)
**And** the next render reconstructs the WebView with the new
`proxySettings` map applied to the per-site `WKWebsiteDataStore`
**And** subsequent requests route through the new proxy
**And** no app restart is required

The `WKWebsiteDataStore.proxyConfigurations` API is bound at
`WKWebView.init` and frozen on the live view, so swapping the proxy
without rebuilding the WebView is not possible — the dispose-and-rebuild
behavior is intentional.

---

### Requirement: PROXY-004 - Proxy Settings Persistence

Proxy settings SHALL persist across app restarts.

#### Scenario: Restore proxy settings on restart

**Given** a site is configured with SOCKS5 proxy "localhost:9050"
**When** the app is closed and reopened
**Then** the site still uses the SOCKS5 proxy configuration

---

### Requirement: PROXY-005 - Proxy Address Validation

The system SHALL validate proxy addresses before applying them.

#### Scenario: Validate proxy address format

**Given** the user is configuring a proxy
**When** the user enters an invalid address (e.g., "proxy.example.com" without port)
**Then** an error message is displayed: "Format: host:port"
**And** the settings are not saved

#### Scenario: Validate port range

**Given** the user is configuring a proxy
**When** the user enters "proxy.example.com:99999"
**Then** an error message is displayed: "Invalid port number"
**And** the settings are not saved

#### Scenario: Native side rejects malformed maps

**Given** the iOS / macOS path receives a `proxySettings` map missing
required keys (`type`, `host`, `port`) or with an out-of-range port
**Then** `inapp.ProxySettings.fromMap` returns an empty array
**And** the per-site data store's `proxyConfigurations` is cleared
**And** the site falls back to system default routing

---

### Requirement: PROXY-006 - Platform-Aware UI

Proxy configuration UI SHALL only be displayed on supported platforms.

#### Scenario: Hide proxy UI on unsupported platforms

**Given** the app is running on Windows
**When** the user opens site settings
**Then** the proxy configuration options are not displayed
**And** the site uses system default proxy automatically

#### Scenario: Show proxy UI on supported platforms

**Given** the app is running on Android, iOS, macOS, or Linux
**When** the user opens site settings
**Then** the proxy type dropdown and address field are displayed

`PlatformInfo.isProxySupported` returns true unconditionally on iOS and
macOS — the version gate (`#available(iOS 17.0, macOS 14.0, *)`) lives
inside the fork's native code. On older OS versions the per-site proxy
block silently no-ops; the UI shows the controls but the site will route
through system default.

---

### Requirement: PROXY-007 - Localhost Bypass

The proxy configuration SHALL bypass localhost addresses to ensure local
resources work correctly.

#### Scenario: Access localhost without proxy (Android)

**Given** a SOCKS5 proxy is configured on Android
**When** the site accesses localhost:3000
**Then** the request bypasses the proxy via the `<local>` bypass rule
**And** connects directly to localhost

On iOS / macOS the `Network.framework` `ProxyConfiguration` API does not
expose a per-config bypass list; localhost routing is governed by
Apple's defaults (loopback addresses bypass automatically for HTTP
CONNECT and SOCKS5 proxies).

---

### Requirement: PROXY-008 - Android / iOS Concurrency Asymmetry

The system SHALL preserve per-site proxy semantics on every supported
platform. The runtime mechanism differs: iOS 17+ / macOS 14+ MUST run
distinct-proxy sites concurrently; Android MUST serialise them by
disposing any loaded site whose effective proxy differs before the
process-wide override flips, so per-site routing is honored at the cost
of cold-starting mismatched sites on activation.

#### Scenario: iOS / macOS — concurrent per-site proxy

**Given** container mode is active on iOS 17+ / macOS 14+
**And** Site A (`accountA.example.com`) and Site B (`accountB.example.com`)
are both loaded
**When** Site A is configured with proxy P1 and Site B with proxy P2
**Then** each site genuinely uses its own proxy at the same time
**Because** the proxy is attached to the per-site `WKWebsiteDataStore`,
which is partitioned per `siteId`

#### Scenario: Android — proxy-mismatch unload on activation

**Given** Site A is loaded on Android with HTTP proxy P1
**And** Site B is configured with SOCKS5 proxy P2
**When** the user activates Site B
**Then** every loaded site whose effective proxy differs from Site B
(including Site A) is disposed *before*
`ProxyController.setProxyOverride` applies P2 globally
**Because** if any of them stayed loaded, its next outbound request
(XHR, image fetch, ServiceWorker poll, …) would silently route through
P2 — exactly the leak the user's per-site proxy choice was meant to
prevent
**And** the data model preserves Site A's P1 setting; activating Site A
again cold-starts it and flips the global override back to P1

The mismatch detection lives in
[`SiteUnloadEngine.indicesToUnloadForProxyMismatch`](../../../lib/services/site_unload_engine.dart);
"different proxy" is computed via [`resolveEffectiveProxy`] so two sites
both set to `DEFAULT` are equivalent (they share the global proxy), as
are two sites set to the same explicit proxy. This is gated on
`Platform.isAndroid` — iOS / macOS skip it (true concurrent per-site
proxy) and platforms without proxy support have nothing to enforce.

The cost on Android is that switching between sites with mismatched
proxies forces a cold-start of whichever side gets unloaded; on iOS /
macOS the same two sites can be loaded concurrently. The data model is
identical across platforms — only the runtime concurrency differs.

#### Scenario: Mixing platforms via settings backup

**Given** a settings backup is exported on iOS with two distinct
per-site proxies
**When** the backup is imported on Android
**Then** both per-site values are preserved in the data model
**And** whichever site is currently active drives the global
`ProxyController` state; switching between them cold-starts the other
under the proxy-mismatch unload rule above

---

### Requirement: PROXY-009 - Per-site DEFAULT inherits global

When a site's [ProxyType] is `DEFAULT`, the effective proxy SHALL fall
through to the app-global outbound proxy configured in App Settings →
Outbound proxy. This applies in both directions: webview navigation
(`ProxyManager.setProxySettings` on Android, `proxySettings` on
iOS / macOS via `resolveEffectiveProxy`) and Dart-side outbound HTTP via
the `outboundHttp` factory.

See [LEAK-001](../ip-leakage/spec.md) for the full precedence ladder and
fail-closed semantics.

#### Scenario: Site with DEFAULT inherits global HTTP proxy

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has Proxy Type `DEFAULT`
**When** the user opens "Acme"
**Then** webview navigation routes through `HTTP 10.0.0.1:8080`
**And** any per-site Dart-side fetch (favicon, download) routes through
`HTTP 10.0.0.1:8080` as well

---

## Data Model

### ProxyType Enum

```dart
enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5 }
```

### UserProxySettings

```dart
class UserProxySettings {
  ProxyType type;
  String? address;   // Format: "host:port"
  String? username;  // Optional credentials
  String? password;
}
```

### iOS / macOS wire format

When passed through `inapp.InAppWebViewSettings.proxySettings`, the
settings are translated by `_proxySettingsToWebspaceProxy` in
[lib/services/webview.dart](../../../lib/services/webview.dart) into:

```dart
{
  'type':     'http' | 'https' | 'socks5',
  'host':     'proxy.example.com',
  'port':     8080,
  'username': 'optional',
  'password': 'optional',
}
```

`ProxyType.DEFAULT`, missing addresses, or malformed entries return
`null`, which the fork's native side interprets as "clear proxy on this
data store".

---

## Architecture

```
lib/settings/proxy.dart
├── ProxyType enum
└── UserProxySettings class

lib/services/webview.dart
├── PlatformInfo.isProxySupported          (Android: feature-flag; iOS/macOS/Linux: always true)
├── ProxyManager.setProxySettings           (Android/Linux: ProxyController; iOS/macOS: no-op)
├── inapp.InAppWebViewSettings.proxySettings
└── _proxySettingsToWebspaceProxy

lib/web_view_model.dart
├── proxySettings field                                (per-site; persisted)
├── _applyProxySettings()                              (Android only)
└── updateProxySettings()                              (Android: ProxyController; iOS/macOS: dispose+rebuild)

lib/screens/settings.dart
└── Proxy configuration UI (per-site; no cross-site sync)

flutter_inappwebview fork (github.com/theoden8/flutter_inappwebview)
├── flutter_inappwebview_ios
├── flutter_inappwebview_macos
│   └── proxySettings field + preWKWebViewConfiguration block
│       + the fork's ProxySettings handling helper (NWEndpoint / ProxyConfiguration builder)
└── flutter_inappwebview_linux
    └── ProxyManager method channel
        ├── webkit_network_session_set_proxy_settings(WEBKIT_NETWORK_PROXY_MODE_CUSTOM)
        └── fan-out across default + every cached container session
            (sessions_to_apply_proxy_to() / container_session_cache())
```

---

## Platform Support

| Platform | Proxy Support | UI Visibility | Behavior |
|----------|--------------|---------------|----------|
| Android  | Full (per-site, serialised) | Shown (when `PROXY_OVERRIDE` feature present) | `inapp.ProxyController` singleton; data model is genuinely per-site, but mismatched-proxy sites cannot stay loaded concurrently — activation cold-starts the conflicting ones (PROXY-008) |
| iOS      | Full (per-site, iOS 17+) | Shown unconditionally | WebSpace fork attaches `proxyConfigurations` to per-site `WKWebsiteDataStore`; iOS <17 silently routes through system default |
| macOS    | Full (per-site, macOS 14+) | Shown unconditionally | Same pattern as iOS; macOS <14 silently routes through system default |
| Linux    | Full (global override, fan-out) | Shown unconditionally | WebSpace fork's `flutter_inappwebview_linux` ProxyManager applies `webkit_network_session_set_proxy_settings` to the default session AND every cached container session, so contained sites honor the global proxy too; per-site is still last-write-wins (no per-site proxy primitive on Linux) |
| Windows  | Limited      | Conditional   | Shown only if `PROXY_OVERRIDE` supported |

---

## Files

### Created
- `lib/settings/proxy.dart` - Proxy types and settings model
- `test/proxy_test.dart` - Unit tests
- `test/proxy_integration_test.dart` - Integration tests
- WebSpace fork of `flutter_inappwebview` (github.com/theoden8/flutter_inappwebview) -
  per-site `proxySettings` field on `flutter_inappwebview_ios` /
  `flutter_inappwebview_macos`, plus `the fork's ProxySettings handling` helper

### Modified
- `lib/services/webview.dart` - `inapp.InAppWebViewSettings.proxySettings`, ProxyManager iOS no-op, PlatformInfo iOS gate
- `lib/web_view_model.dart` - per-site proxy passed into `WebViewConfig`; iOS rebuild on update
- `lib/screens/settings.dart` - per-site proxy UI (no cross-site sync)
- `lib/services/site_unload_engine.dart` - `indicesToUnloadForProxyMismatch` enforces single-proxy-at-a-time on Android

---

## Manual Test Procedure

### iOS / macOS concurrent per-site proxy

1. Add two sites that share a base domain (e.g. two `github.com` accounts).
2. Configure Site A with HTTP proxy `127.0.0.1:8080` and Site B with
   SOCKS5 proxy `127.0.0.1:9050` (run two local proxies of different
   shapes — `mitmproxy` and `dante`, for example).
3. Open Site A: requests must show up in `mitmproxy` only.
4. Switch to Site B without unloading Site A (container mode allows both
   to be loaded simultaneously): requests must show up in `dante` only.
5. Both proxies should remain active for their respective sites.

### Android serialised per-site proxy

1. Same setup as above on Android.
2. Save Site A's config: per-site value is stored in Site A's
   `proxySettings`. Save Site B's config: per-site value is stored in
   Site B's `proxySettings`. Site A's stored value is unchanged.
3. Open Site A: requests show up in `mitmproxy`.
4. Switch to Site B: Site A is disposed by `indicesToUnloadForProxyMismatch`
   *before* the global override flips to Site B's proxy; requests show
   up in `dante` only. Site A's `proxySettings` still contains its
   original value.
5. Switch back to Site A: Site B is disposed; the global flips to Site
   A's proxy; Site A cold-starts and routes through `mitmproxy`.

### Older OS fallback

1. Configure a non-DEFAULT proxy on iOS 16 or macOS 13.
2. Page loads should succeed and route through system default — the
   patched `#available(iOS 17.0, macOS 14.0, *)` block silently no-ops.
3. The UI should still allow the configuration (no crash), matching
   `PlatformInfo.isProxySupported = true`.
