# Known Issues

## webview_cef Warnings (Linux Desktop)

### 1. CEF Cache Path Warning
```
[WARNING:resource_util.cc(83)] Please customize CefSettings.root_cache_path
```

**Status**: Cosmetic warning, doesn't affect functionality  
**Impact**: None - CEF uses default cache path  
**Fix**: Would require PR to webview_cef to expose cache path configuration  
**Workaround**: Can be safely ignored

### 2. Platform Thread Warning
```
[ERROR:flutter/shell/common/shell.cc(1178)] The 'webview_cef' channel sent a message from native to Flutter on a non-platform thread
```

**Status**: Bug in webview_cef plugin (not our code)  
**Impact**: Shouldn't cause crashes in practice, but technically incorrect  
**Fix**: Needs to be fixed in webview_cef plugin upstream  
**Issue**: https://github.com/hlwhl/webview_cef/issues  
**Workaround**: Can be safely ignored for now

### Summary

Both warnings are from the webview_cef plugin itself (version 0.2.2):
- ✅ **App works correctly** despite these warnings
- ✅ **No data loss** observed in testing
- ✅ **No crashes** from these warnings
- ⚠️ **Upstream fixes needed** in webview_cef plugin

These are limitations of using an early-stage plugin (0.2.x). The plugin is actively developed and these issues may be fixed in future versions.

## Alternatives Considered

If these warnings become problematic, alternatives include:
1. **Wait for webview_cef updates** (most likely - plugin is actively developed)
2. **Fork webview_cef** and fix the threading issue ourselves
3. **Switch to flutter_linux_webview** (but has different stability issues)
4. **Contribute fixes upstream** to webview_cef

## Current Recommendation

**Keep using webview_cef** because:
- It actually works on Linux (unlike webview_flutter)
- Warnings are cosmetic/non-critical
- Plugin is actively maintained (latest release Nov 2024)
- Best available option for Flutter Linux webviews currently
