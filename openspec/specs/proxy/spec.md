# Proxy Feature Specification

## Purpose

The proxy feature allows users to configure HTTP, HTTPS, and SOCKS5 proxies
for their web views on supported platforms. Two delivery paths coexist:

- **Android** — global override via `inapp.ProxyController` (a process-wide
  WebView singleton).
- **iOS 17+ / macOS 14+** — true per-site override via
  `WKWebsiteDataStore.proxyConfigurations`, set on the per-site data store
  created by the patched `preWKWebViewConfiguration`. See
  [`third_party/PATCHES.md`](../../../third_party/PATCHES.md).

This asymmetry is observable to the user; see
[PROXY-008](#requirement-proxy-008---android-iOS-isolation-asymmetry-under-profile-mode).

## Status

- **Status**: Completed
- **Platforms**: Android (global override), iOS 17+ / macOS 14+ (true per-site);
  Linux, Windows (system default — UI hidden).

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
concurrently under [profile mode](../per-site-profiles/spec.md))
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** Site A routes traffic through the SOCKS5 proxy
**And** Site B routes traffic through the HTTP proxy at the same time

#### Scenario: Configure different proxies per site (Android)

**Given** Site A and Site B exist on Android
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** the data model stores both per-site values
**And** the implementation propagates the most recently saved value to
every loaded site (see PROXY-008 for the underlying API constraint)

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
`webspaceProxy` map applied to the per-site `WKWebsiteDataStore`
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

**Given** the iOS / macOS path receives a `webspaceProxy` map missing
required keys (`type`, `host`, `port`) or with an out-of-range port
**Then** `WebSpaceProxy.configurations(from:)` returns an empty array
**And** the per-site data store's `proxyConfigurations` is cleared
**And** the site falls back to system default routing

---

### Requirement: PROXY-006 - Platform-Aware UI

Proxy configuration UI SHALL only be displayed on supported platforms.

#### Scenario: Hide proxy UI on unsupported platforms

**Given** the app is running on Linux
**When** the user opens site settings
**Then** the proxy configuration options are not displayed
**And** the site uses system default proxy automatically

#### Scenario: Show proxy UI on supported platforms

**Given** the app is running on Android, iOS, or macOS
**When** the user opens site settings
**Then** the proxy type dropdown and address field are displayed

`PlatformInfo.isProxySupported` returns true unconditionally on iOS and
macOS — the version gate (`#available(iOS 17.0, macOS 14.0, *)`) lives
inside the patched native code. On older OS versions the per-site proxy
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

### Requirement: PROXY-008 - Android / iOS Isolation Asymmetry under Profile Mode

The system SHALL behave differently on Android and iOS when multiple
sites share a base domain and are loaded concurrently under
[per-site profile mode](../per-site-profiles/spec.md).

#### Scenario: iOS / macOS — true per-site proxy

**Given** profile mode is active on iOS 17+ / macOS 14+
**And** Site A (`accountA.example.com`) and Site B (`accountB.example.com`)
are both loaded
**When** Site A is configured with proxy P1 and Site B with proxy P2
**Then** each site genuinely uses its own proxy at the same time
**Because** the proxy is attached to the per-site `WKWebsiteDataStore`,
which is partitioned per `siteId`

#### Scenario: Android — global last-write-wins

**Given** profile mode is active on Android (System WebView 110+)
**And** Site A and Site B share a base domain and are both loaded
**When** Site A is configured with proxy P1 and Site B with proxy P2
**Then** the underlying `inapp.ProxyController.setProxyOverride` applies
the most recently set proxy globally to every WebView in the process
**And** the app's UI sync (`onProxySettingsChanged` in
[lib/screens/settings.dart](../../../lib/screens/settings.dart)) copies
the same proxy into every `WebViewModel.proxySettings` field on save —
so the data model stays consistent with the runtime behavior, but the
"per-site" promise of the UI is effectively reduced to "global".

#### Scenario: Mixing platforms via settings backup

**Given** a settings backup is exported on iOS with two distinct
per-site proxies
**When** the backup is imported on Android
**Then** both per-site values are preserved in the data model
**And** whichever site is opened most recently (or saved last) drives
the global `ProxyController` state

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

When passed through `WebSpaceInAppWebViewSettings.webspaceProxy`, the
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
`null`, which the patched native side interprets as "clear proxy on this
data store".

---

## Architecture

```
lib/settings/proxy.dart
├── ProxyType enum
└── UserProxySettings class

lib/services/webview.dart
├── PlatformInfo.isProxySupported          (Android: feature-flag; iOS/macOS: always true)
├── ProxyManager.setProxySettings           (Android: ProxyController; iOS/macOS: no-op)
├── WebSpaceInAppWebViewSettings.webspaceProxy
└── _proxySettingsToWebspaceProxy

lib/web_view_model.dart
├── proxySettings field                                (per-site; persisted)
├── _applyProxySettings()                              (Android only)
└── updateProxySettings()                              (Android: ProxyController; iOS/macOS: dispose+rebuild)

lib/screens/settings.dart
└── Proxy configuration UI; cross-site sync gated to Android only

third_party/flutter_inappwebview_ios.patch
third_party/flutter_inappwebview_macos.patch
└── webspaceProxy field + preWKWebViewConfiguration block
    + WebSpaceProxy.swift helper (NWEndpoint / ProxyConfiguration builder)
```

---

## Platform Support

| Platform | Proxy Support | UI Visibility | Behavior |
|----------|--------------|---------------|----------|
| Android  | Full (global override) | Shown (when `PROXY_OVERRIDE` feature present) | `inapp.ProxyController` singleton; per-site config in data model is sync'd globally on save (PROXY-008) |
| iOS      | Full (per-site, iOS 17+) | Shown unconditionally | Patched plugin attaches `proxyConfigurations` to per-site `WKWebsiteDataStore`; iOS <17 silently routes through system default |
| macOS    | Full (per-site, macOS 14+) | Shown unconditionally | Same pattern as iOS; macOS <14 silently routes through system default |
| Linux    | None         | Hidden        | DEFAULT proxy forced, UI hidden |
| Windows  | Limited      | Conditional   | Shown only if `PROXY_OVERRIDE` supported |

---

## Files

### Created
- `lib/settings/proxy.dart` - Proxy types and settings model
- `test/proxy_test.dart` - Unit tests
- `test/proxy_integration_test.dart` - Integration tests
- `third_party/flutter_inappwebview_ios.patch` - per-site `webspaceProxy` field, `WebSpaceProxy.swift`
- `third_party/flutter_inappwebview_macos.patch` - sister copy

### Modified
- `lib/services/webview.dart` - `WebSpaceInAppWebViewSettings.webspaceProxy`, ProxyManager iOS no-op, PlatformInfo iOS gate
- `lib/web_view_model.dart` - per-site proxy passed into `WebViewConfig`; iOS rebuild on update
- `lib/screens/settings.dart` - cross-site proxy sync gated to Android only

---

## Manual Test Procedure

### iOS / macOS true per-site proxy

1. Add two sites that share a base domain (e.g. two `github.com` accounts).
2. Configure Site A with HTTP proxy `127.0.0.1:8080` and Site B with
   SOCKS5 proxy `127.0.0.1:9050` (run two local proxies of different
   shapes — `mitmproxy` and `dante`, for example).
3. Open Site A: requests must show up in `mitmproxy` only.
4. Switch to Site B without unloading Site A (profile mode allows both
   to be loaded simultaneously): requests must show up in `dante` only.
5. Both proxies should remain active for their respective sites.

### Android global last-write-wins

1. Same setup as above on Android.
2. Save Site A's config, then Site B's: every WebView (including Site A)
   now routes through Site B's proxy.
3. The settings UI's cross-site sync should also have copied Site B's
   proxy into Site A's `proxySettings` — the data model and the runtime
   behavior should match.

### Older OS fallback

1. Configure a non-DEFAULT proxy on iOS 16 or macOS 13.
2. Page loads should succeed and route through system default — the
   patched `#available(iOS 17.0, macOS 14.0, *)` block silently no-ops.
3. The UI should still allow the configuration (no crash), matching
   `PlatformInfo.isProxySupported = true`.
