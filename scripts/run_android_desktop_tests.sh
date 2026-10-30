#!/usr/bin/env bash
# Android desktop tier (NAV-019, INTEG-018): integration_test/android_desktop_test.dart
# on an Android desktop emulator, where the app opens in a window with a
# header and a keyboard and a mouse drive it. WS_DESKTOP_TIER tells the test
# it is on that tier; without it the file skips, as it does on the phone and
# TV emulators and the desktop jobs.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/android_desktop_test.dart 20 --define WS_DESKTOP_TIER=true
