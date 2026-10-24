#!/usr/bin/env bash
# Android TV tier (NAV-016, HS-004): integration_test/remote_tv_test.dart on
# an Android TV emulator, the one device class where a remote drives the app.
# WS_TV_TIER tells the test it is on that tier; without it the file skips, as
# it does on the phone emulator and the desktop jobs.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/remote_tv_test.dart 20 --define WS_TV_TIER=true
