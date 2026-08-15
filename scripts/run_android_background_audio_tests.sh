#!/usr/bin/env bash
# Android-emulator background-audio tier (BGAUDIO-002 / BGAUDIO-005): run the
# background-audio integration tests against a real Android WebView, where
# `pauseTimers()` is actually implemented. That makes provable here two things
# the Linux/WPE + macOS runs and the pure-Dart engine tests cannot:
#   - the exempt direction end-to-end (a background-audio site keeps ticking
#     across an injected background window), and
#   - the negative control (a plain site's JS timers genuinely freeze).
#
# Single flat invocations, one per file: reactivecircus/android-emulator-runner
# runs each CI `script:` line as a separate `sh -c`, and this script keeps the
# device id in scope across both `flutter test` calls.
set -euo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

status=0
for t in \
  integration_test/background_audio_lifecycle_test.dart \
  integration_test/background_audio_freeze_test.dart; do
  echo "::group::$t"
  # Hard per-test wall-clock cap: a webview mount can deadlock below the Dart
  # timeout layer (same rationale as the white-screen tier).
  rc=0
  timeout -k 30s 12m fvm flutter test "$t" -d "$device_id" --flavor fdebug || rc=$?
  if [ $rc -ne 0 ]; then
    status=$rc
    [ $rc -eq 124 ] && echo "::error::$t killed after 12m wall-clock cap"
  fi
  echo "::endgroup::"
done
exit $status
