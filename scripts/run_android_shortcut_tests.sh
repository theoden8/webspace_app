#!/usr/bin/env bash
# Android-emulator home-shortcut tier (INTEG-013): drive the launch, menu
# gating, orphan routing and delete-time tile prompts of the home-shortcut
# spec against a real Android build, where the `Platform.isAndroid` gates in
# lib/main.dart are actually live. The warm-tap half (a launcher tap arriving
# as onNewIntent) is out of process, in run_android_lifecycle_tests.sh.
#
# Own entry point because reactivecircus/android-emulator-runner runs each CI
# `script:` line as a separate `sh -c`, so the device id has to stay in scope
# with the `flutter test` call.
set -euo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# Hard wall-clock cap, like the sibling tiers. It is the backstop, not the
# first line: every test in the suite carries its own `timeout:` so a hung one
# fails with its widget-tree and log dump instead of silently eating the cap.
exec timeout -k 30s 20m fvm flutter test \
  integration_test/shortcut_behavior_test.dart \
  -d "$device_id" --flavor fdebug
