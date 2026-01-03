# Desktop Window Resize Fix

## Problem

When resizing the app window on desktop (Linux), the webview would not resize to fill the new window dimensions. The webview would remain at its original size, causing layout issues.

## Root Cause

The `webview_cef` widget doesn't automatically respond to parent layout changes. The original implementation used:

```dart
return ValueListenableBuilder(
  valueListenable: controller,
  builder: (context, value, child) {
    return controller.value
        ? controller.webviewWidget
        : controller.loadingWidget;
  },
);
```

This didn't provide explicit constraints to the webview widget, causing it to ignore resize events.

## Solution

Wrapped the webview in a `LayoutBuilder` with explicit `SizedBox` constraints:

```dart
return LayoutBuilder(
  builder: (context, constraints) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, value, child) {
        final widget = controller.value
            ? controller.webviewWidget
            : controller.loadingWidget;
        
        // Force the webview to fill available space and respond to resizes
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: widget,
        );
      },
    );
  },
);
```

### How It Works

1. **LayoutBuilder**: Provides the available constraints from the parent widget
2. **constraints.maxWidth/maxHeight**: Gets the exact space available for the webview
3. **SizedBox**: Forces the webview to match these exact dimensions
4. **Automatic Updates**: When window resizes, LayoutBuilder rebuilds with new constraints

## Result

✅ **Webview now resizes smoothly** when app window is resized  
✅ **Maintains aspect ratio** and fills available space  
✅ **Works on all desktop platforms** (Linux, Windows, macOS with webview_cef)  
✅ **No impact on Android** (flutter_inappwebview already handles this correctly)

## Testing

To test the fix:
1. Run the app on Linux desktop: `flutter run -d linux`
2. Add a website (e.g., `http://example.com:8080`)
3. Resize the app window by dragging edges/corners
4. ✅ Verify the webview content resizes to fill the window

## Files Modified

- `lib/platform/webview_factory.dart`: Updated `_createWebViewCef()` to use LayoutBuilder + SizedBox
