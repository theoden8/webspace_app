# Site Editing & Page Title Display

## Overview

Users can edit site details and see automatic page title extraction instead of just URLs/domains.

---

## Features

### 1. Automatic Page Title Display

**Display Priority**:
1. Page title (from HTML `<title>` tag)
2. Custom name (user-edited)
3. Domain (extracted from URL)

**Locations**:
- App bar (top of screen)
- Drawer list items
- Settings screen

**Example**:
```
Before: example.com
After:  Example Application Portal
```

### 2. Site Editing

**Editable Fields**:
- Site name (custom display name)
- URL (with protocol inference)

**Access Points**:
- Click title in app bar
- Click edit icon (✏️) in drawer
- Both open the same edit dialog

**Protocol Inference**:
- `example.com:8080` → `https://example.com:8080`
- `http://example.com` → stays as HTTP
- `https://example.com` → stays as HTTPS

### 3. Edit Dialog

**Layout**:
```
┌─────────────────────────────┐
│ Edit Site                   │
├─────────────────────────────┤
│ Site Name: [Custom Name   ] │
│ URL: [http://example.com  ] │
│                             │
│ Tip: Include http:// for    │
│ HTTP sites, or leave it out │
│ for HTTPS                   │
├─────────────────────────────┤
│ [Cancel]          [Save]    │
└─────────────────────────────┘
```

**Actions**:
- **Save with URL change**: Recreates webview with new URL
- **Save with name change only**: Updates display name
- **Cancel**: Discards changes

---

## Technical Implementation

### Page Title Tracking

**Data Model**:
```dart
class WebViewModel {
  String name;         // Display name (auto-updated from title)
  String? pageTitle;   // Cached page title
  String initUrl;      // Site URL (now editable)
  
  String getDisplayName() {
    return name; // Returns page title if available
  }
}
```

### Title Fetching

**Android (flutter_inappwebview)**:
```dart
Future<String?> getTitle() async {
  return await controller.getTitle();
}
```

**Linux (webview_cef)**:
```dart
Future<String?> getTitle() async {
  // Parse HTML to extract title
  // (webview_cef doesn't expose getTitle API)
  return await getPageTitle(url);
}
```

### URL Editing Flow

```
User clicks edit → Shows dialog → User modifies URL → Validates input → 
Applies protocol inference → Recreates webview → Loads new URL → Updates display
```

**Code**:
```dart
void _editSite(int index) async {
  final result = await showDialog<Map<String, String>>(...);
  
  if (result != null && result['url'] != oldUrl) {
    setState(() {
      _webViewModels[index].initUrl = newUrl;
      _webViewModels[index].currentUrl = newUrl;
      _webViewModels[index].webview = null;  // Force recreation
      _webViewModels[index].controller = null;
    });
    _saveWebViewModels();
  }
}
```

---

## User Experience

### Before

**Drawer**:
```
[Icon] example.com
       [✏️] [🗑️]
```

**App Bar**:
```
[☰] example.com  [☀️] [⋮]
```

### After

**Drawer**:
```
[Icon] Example Application
       example.com
       [🔄] [✏️] [🗑️]
```

**App Bar**:
```
[☰] Example Application ✏️  [🔄] [☀️] [⋮]
     ↑ Click to edit
```

---

## Persistence

### Save Format (JSON)

```json
{
  "initUrl": "http://example.com:8080",
  "name": "Example Application",
  "pageTitle": "Example Application Portal",
  "cookies": [...],
  "javascriptEnabled": true,
  "userAgent": ""
}
```

### Restoration

```dart
WebViewModel.fromJson(json, stateSetterF)
  ..pageTitle = json['pageTitle'];
```

---

## Platform Support

| Feature | Android | Linux |
|---------|---------|-------|
| Page Title Display | ✅ Native API | ✅ HTML parsing |
| URL Editing | ✅ Yes | ✅ Yes |
| Protocol Inference | ✅ Yes | ✅ Yes |
| Title Persistence | ✅ Yes | ✅ Yes |
| Click-to-Edit | ✅ Yes | ✅ Yes |

---

## Files Modified

### Core Logic
- `lib/web_view_model.dart`
  - Added `pageTitle` field
  - Made `initUrl` non-final (editable)
  - Added `getDisplayName()` method
  - Updated serialization to include `pageTitle`

### Platform Layer
- `lib/platform/webview_factory.dart`
  - Added `getTitle()` to `UnifiedWebViewController`
  - Implemented for both Android and Linux

### UI Layer
- `lib/main.dart`
  - Renamed `_renameSite()` to `_editSite()`
  - Added URL field to edit dialog
  - Updated app bar to show `getDisplayName()`
  - Made app bar title clickable for editing
  - Added edit icon next to title
  - Fetch title on page load via `onUrlChanged`

---

## Future Enhancements

### Potential Improvements
- [ ] JavaScript injection for title on Linux (workaround for webview_cef)
- [ ] "Reset to Default" button in edit dialog
- [ ] Loading indicator during URL change
- [ ] URL validation before saving
- [ ] History of previous URLs
- [ ] Bulk edit for multiple sites
- [ ] Import/export site configurations

### Known Limitations
- Linux webview_cef doesn't expose `getTitle()` natively
- Workaround uses HTTP fetch + HTML parsing
- Cannot get title if site blocks direct HTTP requests
- Title only updates on page load, not dynamic changes
