# Proxy Feature Implementation

## Overview

This document describes the proxy feature implementation for the webspace_app, which allows users to configure HTTP, HTTPS, and SOCKS5 proxies for their web views on Android devices using Flutter InAppWebView's `ProxyController`.

## Features

### Supported Proxy Types

1. **DEFAULT** - Use system proxy settings (no override)
2. **HTTP** - HTTP proxy protocol
3. **HTTPS** - HTTPS proxy protocol  
4. **SOCKS5** - SOCKS5 proxy protocol (ideal for Tor, SSH tunnels, etc.)

### Key Capabilities

- ✅ Global proxy configuration (shared across all webviews)
- ✅ Runtime proxy switching without restart
- ✅ Proxy settings persistence across app restarts
- ✅ Input validation for proxy addresses
- ✅ Support for localhost and remote proxy servers
- ✅ Automatic sync of proxy settings across all sites
- ✅ **Proxy authentication** (username/password for authenticated proxies)
- ✅ Comprehensive test coverage

**Note:** Proxy settings are applied globally via Android's `ProxyController` singleton. Changing proxy on any site updates all sites.

## Architecture

### Component Overview

```
lib/settings/proxy.dart
├── ProxyType enum (DEFAULT, HTTP, HTTPS, SOCKS5)
└── UserProxySettings class (serialization/deserialization)

lib/platform/platform_info.dart
├── initialize() - Async initialization for feature detection
└── isProxySupported - Cached result of WebViewFeature check

lib/platform/unified_webview.dart
└── UnifiedProxyManager (ProxyController singleton integration)

lib/web_view_model.dart
├── proxySettings field
├── _applyProxySettings() method
└── updateProxySettings() method

lib/main.dart
├── PlatformInfo.initialize() called at startup
└── onProxySettingsChanged callback to sync all WebViewModels

lib/screens/settings.dart
├── Proxy configuration UI with validation
├── onProxySettingsChanged callback parameter
└── Helper text explaining shared proxy behavior
```

### Data Flow

```
App Startup
    ↓
PlatformInfo.initialize() - Async WebViewFeature detection
    ↓
isProxySupported cached for synchronous access

User Input (Settings UI)
    ↓
UserProxySettings object
    ↓
WebViewModel.updateProxySettings()
    ↓
UnifiedProxyManager.setProxySettings()
    ↓
ProxyController.setProxyOverride() (singleton - applies globally)
    ↓
Android WebView (proxy applied to ALL webviews)
    ↓
onProxySettingsChanged callback
    ↓
All other WebViewModels updated with same proxy settings
```

## Implementation Details

### 1. Proxy Settings Model (`lib/settings/proxy.dart`)

```dart
enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5 }

class UserProxySettings {
  ProxyType type;
  String? address;   // Format: "host:port"
  String? username;  // Optional: for authenticated proxies
  String? password;  // Optional: for authenticated proxies

  // Returns true if both username and password are provided and non-empty
  bool get hasCredentials => username != null && username!.isNotEmpty
                          && password != null && password!.isNotEmpty;

  // JSON serialization for persistence
  Map<String, dynamic> toJson() { ... }
  factory UserProxySettings.fromJson(Map<String, dynamic> json) { ... }
}
```

### 2. Platform Info (`lib/platform/platform_info.dart`)

Handles async feature detection at app startup:

```dart
class PlatformInfo {
  static bool? _isProxySupportedCached;

  /// Call at app startup to detect proxy support
  static Future<void> initialize() async {
    _isProxySupportedCached = await WebViewFeature.isFeatureSupported(
      WebViewFeature.PROXY_OVERRIDE,
    );
  }

  /// Returns cached result (safe to call synchronously after init)
  static bool get isProxySupported => _isProxySupportedCached ?? false;
}
```

**Why async initialization?**
- `WebViewFeature.isFeatureSupported()` is a Future
- UI code (build methods, initState) must be synchronous
- Caching at startup allows synchronous access throughout the app

### 3. Proxy Manager (`lib/platform/unified_webview.dart`)

The `UnifiedProxyManager` wraps Android's `ProxyController` singleton:

```dart
class UnifiedProxyManager {
  Future<void> setProxySettings(UserProxySettings proxySettings) async {
    // Uses ProxyController.instance() - a SINGLETON
    // Converts UserProxySettings to ProxyController format
    // Handles type-to-scheme mapping (HTTP → http, SOCKS5 → socks5)
    // Builds proxy URL with optional credentials:
    //   - Without auth: scheme://host:port
    //   - With auth: scheme://username:password@host:port
    // Clears proxy when type is DEFAULT
  }

  Future<void> clearProxy() async {
    // Removes proxy override
  }
}
```

**Key Features:**
- Wraps Android's `ProxyController.instance()` singleton
- Proxy settings apply GLOBALLY to all webviews
- Validates proxy address format (host:port)
- Maps ProxyType to appropriate scheme strings
- **Supports authenticated proxies** (username:password in URL)
- URL-encodes credentials to handle special characters
- Includes localhost bypass for local resources

### 4. WebView Integration (`lib/web_view_model.dart`)

Each WebViewModel stores proxy settings (for persistence), but the actual proxy is global:

```dart
class WebViewModel {
  UserProxySettings proxySettings;  // Stored per-model for persistence

  Future<void> setController() async {
    await _applyProxySettings();  // Applied before loading URLs
    // ... other initialization
  }

  Future<void> updateProxySettings(UserProxySettings newSettings) async {
    proxySettings = newSettings;
    await _applyProxySettings();  // Applies to ALL webviews (singleton)
  }
}
```

**Features:**
- Proxy applied before webview loads any content
- Runtime updates via `updateProxySettings()`
- Persisted with other webview settings
- Note: Actual proxy applies globally via ProxyController singleton

### 5. Settings UI (`lib/screens/settings.dart`)

Enhanced settings screen with proxy configuration:

**Components:**
- Platform detection via `PlatformInfo.isProxySupported`
- Helper text: "Proxy settings are shared across all sites."
- Dropdown for proxy type selection (only shown on supported platforms)
- Text field for proxy address (shown when type ≠ DEFAULT)
- **"Proxy requires authentication" checkbox** (shown when type ≠ DEFAULT)
- Username and password fields (shown when checkbox is enabled)
- Password visibility toggle
- Real-time validation
- User feedback via SnackBar
- `onProxySettingsChanged` callback to sync all WebViewModels

**Credentials UI Behavior:**
- Hidden by default behind "Proxy requires authentication" checkbox
- Automatically checked if credentials already exist
- When unchecked, credentials are cleared on save
- Password field has visibility toggle for convenience

**Sync Behavior:**
- When proxy settings are saved, the callback notifies `main.dart`
- All other WebViewModels are updated with the same proxy settings
- Ensures UI consistency across all site settings screens

**Platform-Aware Behavior:**
- On **supported platforms** (Android): Full proxy UI is displayed
- On **unsupported platforms** (Linux, iOS, macOS, etc.): Proxy UI is completely hidden, DEFAULT proxy is forced
- Prevents user confusion by hiding non-functional options

**Validation Rules:**
- Format: `host:port` (e.g., `proxy.example.com:8080`)
- Port range: 1-65535
- Required when proxy type is not DEFAULT
- Validation skipped entirely on unsupported platforms

## Usage Examples

### Example 1: Tor Browser (SOCKS5)

```dart
final torProxy = UserProxySettings(
  type: ProxyType.SOCKS5,
  address: 'localhost:9050',  // Default Tor port
);

await webViewModel.updateProxySettings(torProxy);
```

### Example 2: Corporate HTTP Proxy

```dart
final corpProxy = UserProxySettings(
  type: ProxyType.HTTP,
  address: 'proxy.company.com:8080',
);

await webViewModel.updateProxySettings(corpProxy);
```

### Example 2b: Authenticated Corporate Proxy

```dart
final authProxy = UserProxySettings(
  type: ProxyType.HTTP,
  address: 'proxy.company.com:8080',
  username: 'john.doe',
  password: 'secretpass123',
);

await webViewModel.updateProxySettings(authProxy);
// Proxy URL: http://john.doe:secretpass123@proxy.company.com:8080
```

### Example 3: SSH Tunnel (SOCKS5)

```bash
# Set up SSH tunnel
ssh -D 1080 user@remote-server
```

```dart
final sshProxy = UserProxySettings(
  type: ProxyType.SOCKS5,
  address: '127.0.0.1:1080',
);

await webViewModel.updateProxySettings(sshProxy);
```

### Example 4: Disable Proxy

```dart
final noProxy = UserProxySettings(
  type: ProxyType.DEFAULT,
);

await webViewModel.updateProxySettings(noProxy);
```

## Platform Support

| Platform | Proxy Support | UI Visibility | Behavior |
|----------|--------------|---------------|----------|
| Android  | ✅ Full      | Shown         | ProxyController with all options |
| iOS      | ❌ None      | Hidden        | WebViewFeature not supported |
| Linux    | ❌ None      | Hidden        | InAppWebView not used |
| macOS    | ❌ None      | Hidden        | WebViewFeature throws exception |
| Windows  | ❌ None      | Hidden        | WebViewFeature throws exception |

**Note:** `WebViewFeature.PROXY_OVERRIDE` is only supported on Android. The feature detection uses `WebViewFeature.isFeatureSupported()` which throws on non-Android platforms.

**Platform Detection:**
- `PlatformInfo.initialize()` is called at app startup (in `main.dart`)
- Async detection result is cached in `_isProxySupportedCached`
- `PlatformInfo.isProxySupported` returns the cached value synchronously
- On unsupported platforms:
  - Proxy UI is completely hidden from Settings screen
  - DEFAULT proxy is automatically enforced
  - Users cannot configure proxy settings
  - Prevents confusion from non-functional options
- On supported platforms (Android):
  - Full proxy configuration UI is displayed
  - All proxy types (DEFAULT, HTTP, HTTPS, SOCKS5) are available
  - Helper text explains that proxy is shared across all sites

## Testing

### Test Coverage

The implementation includes comprehensive test coverage:

#### Unit Tests (`test/proxy_test.dart`) - 38 tests
- ProxySettings serialization/deserialization
- ProxyType enum validation
- WebViewModel proxy integration
- Address validation
- Edge cases and error handling
- **Proxy credentials** (15 tests):
  - `hasCredentials` logic (null, empty, valid cases)
  - Credential serialization/deserialization
  - WebViewModel credential persistence
  - Special characters in credentials

#### Integration Tests (`test/proxy_integration_test.dart`) - 12 tests
- End-to-end workflows
- Multi-site configurations
- Persistence and restoration
- Real-world scenarios

**Total: 50 proxy-specific tests**

### Running Tests

```bash
# Run all tests
flutter test

# Run only proxy tests
flutter test test/proxy_test.dart
flutter test test/proxy_integration_test.dart
```

## Common Proxy Ports

| Protocol | Common Ports | Notes |
|----------|-------------|-------|
| HTTP     | 8080, 3128, 8888 | Standard HTTP proxy ports |
| HTTPS    | 443, 8443 | Secure proxy connections |
| SOCKS5   | 1080, 9050 | 9050 is Tor default |

## Troubleshooting

### Issue: Proxy not working

**Solution:**
1. Verify proxy address format: `host:port`
2. Check proxy server is running and accessible
3. Ensure port number is correct
4. Test connectivity: `telnet proxy.example.com 8080`

### Issue: Settings not persisting

**Solution:**
- Proxy settings are saved in WebViewModel JSON
- Ensure app saves state on exit
- Check SharedPreferences implementation

### Issue: "Proxy Error" message

**Possible causes:**
- Invalid address format (missing port, wrong separator)
- Port out of range (must be 1-65535)
- Empty address for non-DEFAULT type

## Security Considerations

1. **Proxy Credentials**:
   - Credentials are stored in the app's SharedPreferences (same as other settings)
   - Passwords are obscured in the UI by default with a visibility toggle
   - Credentials are URL-encoded when applied to handle special characters safely
   - Consider the security implications of storing proxy credentials locally

2. **HTTPS**: When using HTTP proxy for HTTPS traffic, ensure the proxy supports CONNECT tunneling.

3. **Local Bypass**: The implementation bypasses `<local>` addresses to ensure localhost connections work correctly.

4. **Validation**: All proxy addresses are validated before being applied to prevent configuration errors.

5. **Credential Handling**: Credentials with special characters (e.g., `@`, `:`, `/`) are properly URL-encoded to prevent URL parsing issues.

## Future Enhancements

Potential improvements for future versions:

1. **Advanced Authentication**
   - NTLM authentication for corporate proxies
   - Kerberos/GSSAPI support

2. **PAC (Proxy Auto-Config)**
   - Support for PAC file URLs
   - Automatic proxy discovery

3. **Advanced Rules**
   - Per-domain proxy rules
   - Exclude patterns for specific sites
   - Multiple proxy servers with fallback

4. **UI Improvements**
   - Proxy connection testing
   - Saved proxy profiles
   - Recent proxy list

5. **Platform Expansion**
   - Linux proxy support (requires webview_cef update)
   - Native macOS proxy integration

6. **Secure Storage**
   - Store credentials in secure storage (Keychain/Keystore)
   - Biometric protection for proxy credentials

## Code References

### Modified Files

1. `lib/settings/proxy.dart` - Proxy types and settings model
2. `lib/platform/platform_info.dart` - Async feature detection with caching
   - `initialize()` - Async method to detect proxy support at startup
   - `isProxySupported` - Cached getter for synchronous access
3. `lib/platform/unified_webview.dart` - ProxyController integration
4. `lib/main.dart` - App initialization and proxy sync
   - Calls `PlatformInfo.initialize()` before `runApp()`
   - Passes `onProxySettingsChanged` callback to SettingsScreen
   - Callback syncs proxy settings to all WebViewModels
5. `lib/web_view_model.dart` - Proxy application in WebViewModel
6. `lib/screens/settings.dart` - Settings UI with validation and platform detection
   - Added `onProxySettingsChanged` callback parameter
   - Helper text: "Proxy settings are shared across all sites."
   - Conditional UI rendering based on `isProxySupported`
   - Calls callback when proxy settings are saved

### New Files

1. `test/proxy_test.dart` - Unit tests
2. `test/proxy_integration_test.dart` - Integration tests

### Key Methods

- `PlatformInfo.initialize()` - Async feature detection at startup
- `PlatformInfo.isProxySupported` - Cached synchronous getter
- `UnifiedProxyManager.setProxySettings()` - Apply proxy configuration (global)
- `WebViewModel.updateProxySettings()` - Update and apply proxy
- `WebViewModel._applyProxySettings()` - Internal proxy application
- `_SettingsScreenState._validateProxyAddress()` - Input validation
- `_SettingsScreenState._saveSettings()` - Save with validation and sync callback

## References

- [Flutter InAppWebView Documentation](https://inappwebview.dev/)
- [ProxyController API](https://inappwebview.dev/docs/proxy)
- [Android WebView Proxy](https://developer.android.com/reference/android/webkit/ProxyController)
- [SOCKS Protocol](https://en.wikipedia.org/wiki/SOCKS)

## Summary

The proxy feature is fully implemented and tested, providing users with flexible proxy configuration options for their webviews. The implementation is robust, well-tested, and follows Flutter best practices.

**Key Features:**
- **Global Proxy**: Proxy settings apply to all webviews (ProxyController is a singleton)
- **Automatic Sync**: Changing proxy on any site updates all other sites' settings
- **Proxy Authentication**: Optional username/password for authenticated proxies
- **Platform-Aware UI**: Automatically hides proxy settings on unsupported platforms
- **Async Feature Detection**: `PlatformInfo.initialize()` properly awaits WebViewFeature check
- **Graceful Degradation**: Forces DEFAULT proxy where proxy override isn't available
- **User-Friendly**: Helper text explains shared proxy behavior; credentials hidden behind checkbox

**Architecture Notes:**
- `ProxyController.instance()` is Android's singleton - proxy applies globally
- Each `WebViewModel` stores proxy settings for persistence
- `onProxySettingsChanged` callback syncs settings across all WebViewModels
- Feature detection is async but cached for synchronous UI access

**Ideal For:**
- Privacy-conscious users (Tor integration) - Android only
- Corporate environments (HTTP/HTTPS proxies) - Android only
- Developers (SSH tunnels, local proxies) - Android only
- Testing and debugging scenarios

**Platform Notes:**
- Only Android supports `WebViewFeature.PROXY_OVERRIDE`
- Other platforms automatically use system proxy settings
- No user intervention needed on unsupported platforms
- Seamless experience across all platforms

All tests pass, including 50 proxy-specific tests covering unit, integration, credentials, and real-world usage scenarios.
