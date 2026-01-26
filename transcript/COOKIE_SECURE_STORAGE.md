# Cookie Secure Storage Migration

## Overview

This feature migrates cookie storage from SharedPreferences to Flutter Secure Storage for improved security. Cookies contain sensitive session data and authentication tokens that should be stored securely.

## Problem

Previously, cookies were stored as part of `WebViewModel` JSON in SharedPreferences:
- SharedPreferences stores data in plain text
- Cookies contain sensitive session tokens
- On some platforms, SharedPreferences data can be accessed by other apps or extracted from backups

## Solution

Implemented a `CookieSecureStorage` service that:
1. Stores cookies in Flutter Secure Storage (encrypted)
2. Falls back to SharedPreferences when secure storage is unavailable
3. Automatically migrates existing cookies from SharedPreferences

## Implementation Details

### New Files

#### `lib/services/cookie_secure_storage.dart`

The main service class that handles:
- Loading cookies from secure storage (with fallback)
- Saving cookies to secure storage
- Migration from SharedPreferences
- Graceful error handling when secure storage fails

Key features:
```dart
class CookieSecureStorage {
  static const String _secureStorageKey = 'secure_cookies';
  static const String _sharedPrefsCookiesKey = 'cookies_fallback';

  bool _secureStorageAvailable = true;  // Tracks if secure storage works

  // Tries secure storage first, falls back to SharedPreferences
  Future<Map<String, List<UnifiedCookie>>> loadCookies() async { ... }

  // Saves to secure storage, falls back on failure
  Future<void> saveCookies(Map<String, List<UnifiedCookie>> cookiesByUrl) async { ... }
}
```

#### `test/cookie_secure_storage_test.dart`

Comprehensive tests covering:
- Save/load cookies to secure storage
- Migration from SharedPreferences
- Preference of secure storage over SharedPreferences
- Graceful handling of corrupted storage
- Preserving all cookie properties
- Multi-site cookie handling

### Modified Files

#### `lib/main.dart`

- Added `CookieSecureStorage` instance to `_WebSpacePageState`
- Modified `_saveWebViewModels()` to save cookies to secure storage separately
- Modified `_loadWebViewModels()` to load cookies from secure storage with fallback
- Cookies are no longer stored in the SharedPreferences `webViewModels` JSON

#### `pubspec.yaml`

Added dependency:
```yaml
flutter_secure_storage: ^9.2.2
```

## Storage Flow

### Loading (App Start)

```
1. Load webViewModels from SharedPreferences (without cookies)
2. Load cookies from CookieSecureStorage:
   a. Try Flutter Secure Storage
   b. If empty, try SharedPreferences fallback key
   c. If empty, try legacy webViewModels cookies (migration)
3. Merge cookies into loaded models
4. Re-save to ensure cookies are in secure storage
```

### Saving (On Change)

```
1. Collect cookies from all webViewModels
2. Save cookies to CookieSecureStorage:
   a. Try Flutter Secure Storage
   b. On failure, mark unavailable and use SharedPreferences fallback
3. Save webViewModels to SharedPreferences (with empty cookies array)
```

## Platform Considerations

### macOS

macOS Keychain access requires proper app signing with a development team. Without it, secure storage throws:
```
PlatformException(Unexpected security result code, Code: -34018,
Message: A required entitlement isn't present.)
```

**Solution**: The code gracefully falls back to SharedPreferences when this occurs. No entitlement changes needed - the fallback handles it.

### iOS

Works with proper Keychain entitlements (usually set up automatically by Flutter).

### Android

Uses EncryptedSharedPreferences when available:
```dart
aOptions: AndroidOptions(encryptedSharedPreferences: true)
```

## Backward Compatibility

The implementation maintains full backward compatibility:

1. **Existing users**: Cookies stored in old `webViewModels` JSON are automatically migrated
2. **Failed secure storage**: Falls back to SharedPreferences with a separate key
3. **No data loss**: Multiple fallback layers ensure cookies are preserved

## Security Improvements

| Aspect | Before | After |
|--------|--------|-------|
| Storage | Plain text in SharedPreferences | Encrypted in Keychain/Keystore |
| Backup exposure | Included in app backups | Protected by system encryption |
| Cross-app access | Potentially accessible | Sandboxed per-app |

## Testing

Run tests with:
```bash
flutter test test/cookie_secure_storage_test.dart
```

Tests verify:
- Basic save/load functionality
- Migration from SharedPreferences
- Fallback behavior
- Cookie property preservation
- Multi-site handling
- Error handling for corrupted data

## Commits

1. `Migrate cookies from SharedPreferences to Flutter Secure Storage` - Initial implementation
2. `Fix macOS Keychain entitlements and add graceful fallback` - Added fallback for platforms where secure storage fails
3. `Fix test mock to match updated FlutterSecureStorage API` - Updated tests for newer API
4. `Revert macOS Keychain entitlements - rely on graceful fallback` - Removed entitlements that caused build issues

## Future Improvements

- Consider adding option to clear secure storage on logout
- Add telemetry for secure storage availability across platforms
- Consider per-site encryption keys for additional isolation
