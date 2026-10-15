#ifndef RUNNER_WINDOW_CAPTURE_H_
#define RUNNER_WINDOW_CAPTURE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#ifndef NDEBUG
// The `window_capture` channel integration_test/screenshot_test.dart drives on
// Linux (SCREENSHOT-009), the counterpart of
// macos/Runner/WindowCapturePlugin.swift: `resize` sets the window's size and
// `capture` returns the window as PNG bytes, the site included. Debug builds
// only: no shipped build can image its own window.
void window_capture_attach(FlView* view, GtkWindow* window);
#endif  // NDEBUG

#endif  // RUNNER_WINDOW_CAPTURE_H_
