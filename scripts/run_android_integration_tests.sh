#!/usr/bin/env bash
# Android-emulator in-process integration tier: the white-screen pixel
# scenarios (INTEG-010) and the home-shortcut behavior scenarios
# (INTEG-013), against the first connected device/emulator.
#
# Single entry point because reactivecircus/android-emulator-runner
# executes each script line as a separate `sh -c` invocation: a variable
# assignment does not survive to the next line, and a backslash-continued
# command is split mid-line (observed as flutter test loading a target
# literally named "\").
set -euo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# Hard wall-clock cap per suite: a webview mount can deadlock below the
# Dart timeout layer (same rationale as the desktop integration loops).
# It is the backstop, not the first line: each suite's tests carry their
# own `timeout:` so a hung test fails with its diagnostics instead of
# silently eating the cap and killing the step with exit 124.
for target in white_screen_test shortcut_behavior_test; do
  echo "::group::integration_test/$target.dart"
  timeout -k 30s 25m fvm flutter test \
    "integration_test/$target.dart" \
    -d "$device_id" --flavor fdebug
  echo "::endgroup::"
done
