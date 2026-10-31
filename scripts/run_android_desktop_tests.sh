#!/usr/bin/env bash
# Android desktop tier (NAV-019, INTEG-018): integration_test/android_desktop_test.dart
# on an Android desktop emulator, where the app opens in a window with a
# header and a keyboard and a mouse drive it. WS_DESKTOP_TIER tells the test
# it is on that tier; without it the file skips, as it does on the phone and
# TV emulators and the desktop jobs.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
adb_() { adb -s "$device_id" "$@"; }

# Awake, with no lock screen over the app the test starts.
adb_ shell input keyevent KEYCODE_WAKEUP || true
adb_ shell wm dismiss-keyguard || true
adb_ shell input keyevent 82 || true
adb_ shell svc power stayon true || true

run_tier integration_test/android_desktop_test.dart 20 --define WS_DESKTOP_TIER=true
