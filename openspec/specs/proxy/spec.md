# Proxy Feature Specification

## Purpose

The proxy feature allows users to configure HTTP, HTTPS, and SOCKS5 proxies for their web views on supported platforms using Flutter InAppWebView's ProxyController.

## Status

- **Status**: Completed
- **Platforms**: Android, iOS (full support); Linux, macOS, Windows (system default)

---

## Requirements

### Requirement: PROXY-001 - Supported Proxy Types

The system SHALL support the following proxy types:

1. **DEFAULT** - Use system proxy settings (no override)
2. **HTTP** - HTTP proxy protocol
3. **HTTPS** - HTTPS proxy protocol
4. **SOCKS5** - SOCKS5 proxy protocol (ideal for Tor, SSH tunnels, etc.)

#### Scenario: Select HTTP proxy type

**Given** the user is on the settings screen for a site
**When** the user selects "HTTP" from the Proxy Type dropdown
**And** enters "proxy.example.com:8080" as the address
**And** saves settings
**Then** the site uses the HTTP proxy for all requests

---

### Requirement: PROXY-002 - Per-Webview Proxy Configuration

Each webview SHALL have its own independent proxy configuration.

#### Scenario: Configure different proxies per site

**Given** Site A and Site B exist
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** Site A routes traffic through the SOCKS5 proxy
**And** Site B routes traffic through the HTTP proxy

---

### Requirement: PROXY-003 - Runtime Proxy Switching

Users SHALL be able to change proxy settings without restarting the app.

#### Scenario: Change proxy at runtime

**Given** a site is currently using DEFAULT proxy
**When** the user changes to SOCKS5 proxy "localhost:9050"
**And** saves settings
**Then** the proxy change takes effect immediately
**And** no app restart is required

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

---

### Requirement: PROXY-006 - Platform-Aware UI

Proxy configuration UI SHALL only be displayed on supported platforms.

#### Scenario: Hide proxy UI on unsupported platforms

**Given** the app is running on Linux
**When** the user opens site settings
**Then** the proxy configuration options are not displayed
**And** the site uses system default proxy automatically

#### Scenario: Show proxy UI on supported platforms

**Given** the app is running on Android
**When** the user opens site settings
**Then** the proxy type dropdown and address field are displayed

---

### Requirement: PROXY-007 - Localhost Bypass

The proxy configuration SHALL bypass localhost addresses to ensure local resources work correctly.

#### Scenario: Access localhost without proxy

**Given** a SOCKS5 proxy is configured
**When** the site accesses localhost:3000
**Then** the request bypasses the proxy
**And** connects directly to localhost

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
  String? address;  // Format: "host:port"
}
```

---

## Architecture

```
lib/settings/proxy.dart
├── ProxyType enum
└── UserProxySettings class

lib/platform/unified_webview.dart
└── UnifiedProxyManager (ProxyController integration)

lib/web_view_model.dart
├── proxySettings field
├── _applyProxySettings() method
└── updateProxySettings() method

lib/screens/settings.dart
└── Proxy configuration UI with validation
```

---

## Platform Support

| Platform | Proxy Support | UI Visibility | Behavior |
|----------|--------------|---------------|----------|
| Android  | Full         | Shown         | ProxyController with all options |
| iOS      | Full         | Shown         | ProxyController with all options |
| Linux    | None         | Hidden        | DEFAULT proxy forced, UI hidden |
| macOS    | Limited      | Conditional   | Shown only if PROXY_OVERRIDE supported |
| Windows  | Limited      | Conditional   | Shown only if PROXY_OVERRIDE supported |

---

## Files

### Created
- `lib/settings/proxy.dart` - Proxy types and settings model
- `test/proxy_test.dart` - Unit tests (23 tests)
- `test/proxy_integration_test.dart` - Integration tests (12 tests)

### Modified
- `lib/platform/unified_webview.dart` - ProxyController integration
- `lib/web_view_model.dart` - Proxy application in WebViewModel
- `lib/screens/settings.dart` - Settings UI with validation and platform detection
