#!/usr/bin/env bash
# Android-emulator background-audio tier (BGAUDIO-002 / BGAUDIO-005): run the
# background-audio integration tests against a real Android WebView, where
# `pauseTimers()` is actually implemented. That makes provable here two things
# the Linux/WPE + macOS runs and the pure-Dart engine tests cannot:
#   - the exempt direction end-to-end (a background-audio site keeps ticking
#     across an injected background window),
#   - the negative control (a plain site's JS timers genuinely freeze), and
#   - BGAUDIO-006, the media notification: the foreground service and its
#     MediaStyle notification only exist on Android, so this is the only tier
#     that can assert the user-visible half of the feature.
#
# Single flat invocations, one per file: reactivecircus/android-emulator-runner
# runs each CI `script:` line as a separate `sh -c`, and this script keeps the
# device id in scope across the `flutter test` calls.
set -euo pipefail

PKG="org.codeberg.theoden8.webspace"

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# POST_NOTIFICATIONS is pre-granted so the notification tier measures the
# feature, not the permission dialog: on API 33+ a denied grant leaves the
# foreground service running with nothing on screen, which is exactly the
# failure the test is built to catch — but as a *product* bug, not a harness
# one. `flutter test` installs the app itself, so retry in the background
# until the package exists (same shape as the camera tier).
adb -s "$device_id" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
(
  for _ in $(seq 1 60); do
    if adb -s "$device_id" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1; then
      echo "background-audio tier: POST_NOTIFICATIONS granted to $PKG"
      break
    fi
    sleep 2
  done
) &

status=0
for t in \
  integration_test/background_audio_lifecycle_test.dart \
  integration_test/background_audio_freeze_test.dart \
  integration_test/background_audio_media_notification_test.dart; do
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
