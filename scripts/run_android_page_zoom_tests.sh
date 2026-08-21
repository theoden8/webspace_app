#!/usr/bin/env bash
# Android-emulator page-zoom tier (BUG-008): the per-site zoom contract
# against a real Android System WebView on the first connected
# device/emulator.
#
# The Linux and macOS integration jobs run the same file against WPE and
# WKWebView, but only Android System WebView has the wide-viewport quirk
# that put every zoomed site on the 980px desktop layout, and it is
# reachable from no other engine.
#
# Single entry point for the same reason as the white-screen tier:
# reactivecircus/android-emulator-runner executes each script line as a
# separate `sh -c`, so a variable assignment does not survive to the next
# line.
set -euo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# Hard wall-clock cap: a webview mount can deadlock below the Dart timeout
# layer (same rationale as the white-screen tier).
exec timeout -k 30s 15m fvm flutter test \
  integration_test/page_zoom_test.dart \
  -d "$device_id" --flavor fdebug
