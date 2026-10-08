#!/usr/bin/env bash
# Android-emulator integration tier (INTEG-010): white-screen pixel
# scenarios against the first connected device/emulator.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/white_screen_test.dart 25
