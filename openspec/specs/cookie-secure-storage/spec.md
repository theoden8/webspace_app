# Cookie Secure Storage Specification

## Purpose

This feature migrates cookie storage from SharedPreferences to Flutter Secure Storage for improved security. Cookies contain sensitive session data and authentication tokens that should be stored securely.

## Status

- **Status**: Completed

---

## Problem Statement

Previously, cookies were stored as part of WebViewModel JSON in SharedPreferences:
- SharedPreferences stores data in plain text
- Cookies contain sensitive session tokens
- On some platforms, SharedPreferences data can be accessed by other apps or extracted from backups

---

## Requirements

### Requirement: COOKIE-001 - Secure Storage Primary

Cookies SHALL be stored in Flutter Secure Storage (encrypted) as the primary storage method.

#### Scenario: Save cookies securely

**Given** a user visits a website and receives cookies
**When** the cookies are saved
**Then** they are stored in Flutter Secure Storage
**And** they are encrypted at rest

---

### Requirement: COOKIE-002 - Fallback to SharedPreferences

The system SHALL fall back to SharedPreferences when secure storage is unavailable.

#### Scenario: Handle secure storage failure

**Given** Flutter Secure Storage is unavailable (e.g., macOS without entitlements)
**When** the system attempts to save cookies
**Then** cookies are saved to SharedPreferences instead
**And** the app continues to function normally

---

### Requirement: COOKIE-003 - Automatic Migration

The system SHALL automatically migrate existing cookies from SharedPreferences to secure storage.

#### Scenario: Migrate legacy cookies

**Given** a user has cookies stored in the old SharedPreferences format
**When** the app starts after the update
**Then** cookies are migrated to Flutter Secure Storage
**And** the migration is transparent to the user

---

### Requirement: COOKIE-004 - Graceful Error Handling

The system SHALL handle storage errors gracefully without data loss.

#### Scenario: Recover from corrupted storage

**Given** the secure storage contains corrupted data
**When** the app attempts to load cookies
**Then** the error is caught gracefully
**And** empty cookies are returned (no crash)

---

### Requirement: COOKIE-005 - Multi-Site Cookie Handling

The system SHALL correctly handle cookies for multiple sites.

#### Scenario: Separate cookies per site

**Given** Site A has cookies [cookie1, cookie2]
**And** Site B has cookies [cookie3]
**When** cookies are saved and restored
**Then** Site A receives [cookie1, cookie2]
**And** Site B receives [cookie3]

---

### Requirement: COOKIE-006 - Secure Flag Enforcement

Cookies SHALL be stored based on their `isSecure` flag:
- `isSecure=true` → Flutter Secure Storage only
- `isSecure=false` → SharedPreferences

#### Scenario: Secure cookie stored in secure storage

**Given** Site A has a cookie with `isSecure=true`
**When** the cookie is persisted
**Then** it is stored in Flutter Secure Storage (Keychain/Keystore)
**And** it is NOT written to SharedPreferences

#### Scenario: Non-secure cookie stored in SharedPreferences

**Given** Site A has a cookie with `isSecure=false`
**When** the cookie is persisted
**Then** it is stored in SharedPreferences
**And** it is NOT written to Flutter Secure Storage

#### Scenario: Mixed cookies split by storage

**Given** Site A has cookies with mixed `isSecure` flags
**When** cookies are persisted
**Then** secure cookies go to Flutter Secure Storage
**And** non-secure cookies go to SharedPreferences
**And** loading merges cookies from both storages

---

## Storage Flow

### Loading (App Start)

1. Load webViewModels from SharedPreferences (without cookies)
2. Load cookies from CookieSecureStorage:
   a. Try Flutter Secure Storage
   b. If empty, try SharedPreferences fallback key
   c. If empty, try legacy webViewModels cookies (migration)
3. Merge cookies into loaded models
4. Re-save to ensure cookies are in secure storage

### Saving (On Change)

1. Collect cookies from all webViewModels
2. Save cookies to CookieSecureStorage:
   a. Try Flutter Secure Storage
   b. On failure, mark unavailable and use SharedPreferences fallback
3. Save webViewModels to SharedPreferences (with empty cookies array)

---

## Platform Considerations

### macOS

macOS Keychain access requires proper app signing with a development team. Without it, secure storage throws:
```
PlatformException(Code: -34018, Message: A required entitlement isn't present.)
```

**Solution**: The code gracefully falls back to SharedPreferences.

### iOS

Works with proper Keychain entitlements (usually set up automatically by Flutter).

### Android

Uses EncryptedSharedPreferences when available:
```dart
aOptions: AndroidOptions(encryptedSharedPreferences: true)
```

---

## Security Improvements

| Aspect | Before | After |
|--------|--------|-------|
| Storage | Plain text in SharedPreferences | Encrypted in Keychain/Keystore |
| Backup exposure | Included in app backups | Protected by system encryption |
| Cross-app access | Potentially accessible | Sandboxed per-app |

---

## Files

### Created
- `lib/services/cookie_secure_storage.dart` - Core storage service
- `test/cookie_secure_storage_test.dart` - Unit tests

### Modified
- `lib/main.dart` - Integration with secure storage
- `pubspec.yaml` - Added `flutter_secure_storage: ^9.2.2`
