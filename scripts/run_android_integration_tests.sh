#!/usr/bin/env bash
# Android-emulator integration tier (INTEG-010): white-screen pixel
# scenarios against the first connected device/emulator.
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

# Hard wall-clock cap: a webview mount can deadlock below the Dart timeout
# layer (same rationale as the desktop integration loops).
exec timeout -k 30s 25m fvm flutter test \
  integration_test/white_screen_test.dart \
  -d "$device_id" --flavor fdebug
