#!/usr/bin/env bash
# Android-emulator site-icon tier (ICON-009/010/011/014): which page icon a
# real Android System WebView hands to `onReceivedIcon`, and which of those
# the app takes, on the first connected device/emulator. A second run turns
# on Site icons only, under which Android fetches the declared links instead
# (ICON-013) and ignores the callback.
#
# Only Android WebView has the callback, so no other tier reaches this path.
# The macOS integration job runs the same file for the fetch path.
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
run_pass() {
  adb -s "$device_id" logcat -c || true
  local rc=0
  timeout -k 30s 15m fvm flutter test \
    integration_test/site_icon_test.dart \
    -d "$device_id" --flavor fdebug "$@" || rc=$?
  echo "=== logcat after site_icon_test $* (rc=$rc) ==="
  adb -s "$device_id" logcat -d -v time 2>/dev/null |
    grep -E 'SiteIcon|site_icon_test|JavaScriptBridge|IAWebView|InAppWebView|Bridge access|CONSOLE' |
    tail -300 || true
  return $rc
}

fail=0
run_pass || fail=1
run_pass || fail=1
run_pass --dart-define=WS_SITE_ICONS_ONLY=true || fail=1
run_pass --dart-define=WS_SITE_ICONS_ONLY=true || fail=1
exit $fail
