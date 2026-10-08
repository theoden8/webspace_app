#!/usr/bin/env bash
# Android-emulator camera tier (CAM-010): per-site camera modes against a
# real Android WebView on the first connected device/emulator.
#
# CAMERA is pre-granted: without it the real camera scenario reports
# NotAllowedError and skips.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/camera_test.dart 20 --grant CAMERA
