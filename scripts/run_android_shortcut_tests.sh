#!/usr/bin/env bash
# Android-emulator home-shortcut tier (INTEG-013): drive the launch, menu
# gating, orphan routing and delete-time tile prompts of the home-shortcut
# spec against a real Android build, where the `Platform.isAndroid` gates in
# lib/main.dart are actually live. The warm-tap half (a launcher tap arriving
# as onNewIntent) is out of process, in run_android_lifecycle_tests.sh.
#
# The wall-clock cap is the backstop, not the first line: every test in the
# suite carries its own `timeout:` so a hung one fails with its widget-tree
# and log dump instead of silently eating the cap.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/shortcut_behavior_test.dart 20
