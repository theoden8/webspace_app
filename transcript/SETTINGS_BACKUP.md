# Settings Import/Export Feature

## Overview

This document describes the settings import/export feature for the webspace_app, which allows users to backup and restore their app configuration including sites, webspaces, and preferences.

## Features

### Key Capabilities

- Export all settings to a JSON file
- Import settings from a backup file
- Share backup files via system share sheet
- Cookies are **never** included in backups (security measure)
- Version-tagged backups for future compatibility
- Confirmation dialog before importing (shows backup details)

### What's Included in Backups

| Setting | Exported | Notes |
|---------|----------|-------|
| Sites (URLs, names) | Yes | All site configurations |
| Site proxy settings | Yes | Per-site proxy configuration |
| Site user agents | Yes | Custom user agent strings |
| Site JS enabled | Yes | JavaScript toggle state |
| Site 3rd-party cookies | Yes | Third-party cookie setting |
| Webspaces | Yes | Custom webspaces only ("All" is recreated) |
| Theme mode | Yes | Light/dark/system preference |
| URL bar visibility | Yes | Show/hide URL bar setting |
| Selected webspace | Yes | Currently selected webspace ID |
| Current site index | Yes | Last viewed site |
| **Cookies** | **No** | Never exported for security |

## Architecture

### Component Overview

```
lib/services/settings_backup.dart
├── SettingsBackup class (data model)
├── SettingsBackupService
│   ├── createBackup() - creates backup excluding cookies
│   ├── exportToJson() - serializes to JSON string
│   ├── exportAndShare() - exports and opens share sheet
│   ├── importFromJson() - parses JSON to backup object
│   ├── pickAndImport() - opens file picker and imports
│   ├── restoreSites() - converts backup to WebViewModel list
│   └── restoreWebspaces() - converts backup to Webspace list

lib/main.dart
├── _exportSettings() - handler for export menu item
└── _importSettings() - handler for import menu item
```

### Data Flow

#### Export Flow

```
User taps "Export Settings" in menu
    ↓
_exportSettings() called
    ↓
SettingsBackupService.exportAndShare()
    ↓
createBackup() - collects all settings, strips cookies
    ↓
exportToJson() - formats as pretty JSON
    ↓
Write to temp file (webspace_backup_TIMESTAMP.json)
    ↓
Share.shareXFiles() - opens system share sheet
    ↓
Temp file cleaned up after 30 seconds
```

#### Import Flow

```
User taps "Import Settings" in menu
    ↓
_importSettings() called
    ↓
SettingsBackupService.pickAndImport()
    ↓
FilePicker.platform.pickFiles() - user selects .json file
    ↓
importFromJson() - parse and validate
    ↓
Show confirmation dialog with backup details
    ↓
User confirms
    ↓
Clear existing data
    ↓
restoreSites() / restoreWebspaces() - rebuild models
    ↓
Apply theme, save all settings
    ↓
Show success message
```

## Implementation Details

### 1. Backup Data Model (`SettingsBackup`)

```dart
class SettingsBackup {
  final int version;                    // Backup format version
  final List<Map<String, dynamic>> sites;      // Site configurations
  final List<Map<String, dynamic>> webspaces;  // Custom webspaces
  final int themeMode;                  // 0=light, 1=dark, 2=system
  final bool showUrlBar;                // URL bar visibility
  final String? selectedWebspaceId;     // Currently selected webspace
  final int? currentIndex;              // Currently selected site
  final DateTime exportedAt;            // Timestamp of export
}
```

### 2. Cookie Exclusion

Cookies are explicitly stripped during both export and import:

```dart
// In createBackup():
final sitesJson = webViewModels.map((model) {
  final json = model.toJson();
  json['cookies'] = [];  // Remove cookies from export
  return json;
}).toList();

// In restoreSites():
return backup.sites.map((json) {
  json['cookies'] = [];  // Ensure no cookies on import
  return WebViewModel.fromJson(json, stateSetterF);
}).toList();
```

### 3. "All" Webspace Handling

The special "All" webspace is never exported and is always recreated on import:

```dart
// Export excludes "All":
final webspacesJson = webspaces
    .where((ws) => ws.id != kAllWebspaceId)
    .map((ws) => ws.toJson())
    .toList();

// Import recreates "All":
static List<Webspace> restoreWebspaces(SettingsBackup backup) {
  final webspaces = <Webspace>[Webspace.all()];  // Always add "All" first
  for (final json in backup.webspaces) {
    final ws = Webspace.fromJson(json);
    if (ws.id != kAllWebspaceId) {
      webspaces.add(ws);
    }
  }
  return webspaces;
}
```

### 4. Menu Integration

Import/Export options appear in the triple-dot menu only when on the webspaces list screen:

```dart
PopupMenuButton<String>(
  itemBuilder: (BuildContext context) {
    final bool onWebspacesList = _currentIndex == null ||
                                  _currentIndex! >= _webViewModels.length;
    return [
      // ... site-specific menu items ...

      // Import/Export (only on webspaces list screen)
      if (onWebspacesList)
        PopupMenuItem<String>(
          value: "export",
          child: Row(children: [Icon(Icons.upload), Text("Export Settings")]),
        ),
      if (onWebspacesList)
        PopupMenuItem<String>(
          value: "import",
          child: Row(children: [Icon(Icons.download), Text("Import Settings")]),
        ),
    ];
  },
)
```

## Usage

### Exporting Settings

1. Navigate to the webspaces list screen (tap webspace icon or "Back to Webspaces")
2. Tap the triple-dot menu (⋮) in the top-right
3. Select "Export Settings"
4. Choose where to save/share the backup file

### Importing Settings

1. Navigate to the webspaces list screen
2. Tap the triple-dot menu (⋮)
3. Select "Import Settings"
4. Select a `.json` backup file
5. Review the confirmation dialog showing:
   - Number of sites in backup
   - Number of webspaces in backup
   - Export timestamp
   - Note about cookies not being included
6. Tap "Import" to confirm

**Warning**: Importing will replace ALL current settings.

## Backup File Format

Example backup JSON structure:

```json
{
  "version": 1,
  "sites": [
    {
      "initUrl": "https://example.com",
      "currentUrl": "https://example.com/page",
      "name": "Example Site",
      "pageTitle": "Example - Homepage",
      "cookies": [],
      "proxySettings": {
        "type": 0,
        "address": null
      },
      "javascriptEnabled": true,
      "userAgent": "",
      "thirdPartyCookiesEnabled": false
    }
  ],
  "webspaces": [
    {
      "id": "abc123-uuid",
      "name": "Work",
      "siteIndices": [0, 1, 2]
    }
  ],
  "themeMode": 2,
  "showUrlBar": false,
  "selectedWebspaceId": "__all_webspace__",
  "currentIndex": null,
  "exportedAt": "2024-01-15T10:30:00.000Z"
}
```

## Security Considerations

### Why Cookies Are Excluded

1. **Authentication tokens**: Cookies often contain session tokens and auth credentials
2. **Privacy**: Cookie data may contain tracking identifiers
3. **Device-specific**: Cookies are tied to the device/browser context
4. **Security risk**: Exported files could be shared, exposing sensitive data

### Backup File Security

- Backup files are plain JSON (not encrypted)
- Users should treat backup files as potentially sensitive
- Avoid sharing backups publicly if they contain sensitive site configurations
- Proxy credentials (if any) would be included in backup

## Dependencies

The feature requires these packages (added to `pubspec.yaml`):

```yaml
dependencies:
  file_picker: ^8.0.0      # For selecting import files
  share_plus: ^10.0.0      # For sharing export files
  path_provider: ^2.1.0    # For temp directory access
```

## Platform Support

| Platform | Export | Import | Notes |
|----------|--------|--------|-------|
| Android  | Yes | Yes | Full support |
| iOS      | Yes | Yes | Full support |
| macOS    | Yes | Yes | Full support |
| Linux    | Yes | Yes | Full support |
| Windows  | Yes | Yes | Full support |
| Web      | Yes | Yes | Uses bytes instead of file path |

## Error Handling

### Export Errors

- Temp directory unavailable: Shows error snackbar
- Share cancelled: Returns gracefully (not an error)
- JSON encoding failure: Shows error snackbar

### Import Errors

- File picker cancelled: Returns null (no error shown)
- Invalid JSON format: Shows "Invalid backup file format" snackbar
- File read failure: Shows "Could not read the selected file" snackbar
- Parse exception: Shows "Import failed: [error]" snackbar

## Testing

### Test Coverage

The implementation includes tests for:

- Backup creation with various configurations
- Cookie exclusion verification
- JSON serialization/deserialization round-trips
- "All" webspace handling
- Empty and large data sets
- Import after export consistency

### Running Tests

```bash
# Run settings backup tests
fvm flutter test test/settings_backup_test.dart
```

## Code References

### Modified Files

1. `lib/main.dart` - Added menu items and handlers
2. `pubspec.yaml` - Added dependencies

### New Files

1. `lib/services/settings_backup.dart` - Core backup service
2. `test/settings_backup_test.dart` - Unit tests

### Key Methods

- `SettingsBackupService.createBackup()` - Create backup excluding cookies
- `SettingsBackupService.exportAndShare()` - Export and share file
- `SettingsBackupService.pickAndImport()` - Pick and parse backup file
- `SettingsBackupService.restoreSites()` - Restore WebViewModel list
- `SettingsBackupService.restoreWebspaces()` - Restore Webspace list
- `_WebSpacePageState._exportSettings()` - Export menu handler
- `_WebSpacePageState._importSettings()` - Import menu handler

## Future Enhancements

Potential improvements for future versions:

1. **Selective Import**
   - Choose which sites/webspaces to import
   - Merge with existing data instead of replacing

2. **Backup Encryption**
   - Optional password protection
   - Encrypted backup files

3. **Cloud Backup**
   - Sync to cloud storage providers
   - Automatic periodic backups

4. **Backup History**
   - Keep multiple backup versions
   - Compare and restore from history

5. **Partial Export**
   - Export specific webspaces only
   - Export single site configuration
