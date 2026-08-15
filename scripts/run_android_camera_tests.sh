#!/usr/bin/env bash
# Android-emulator camera tier (CAM-010): per-site camera modes against a
# real Android WebView on the first connected device/emulator.
#
# Single entry point for the same reason as the white-screen tier:
# reactivecircus/android-emulator-runner executes each script line as a
# separate `sh -c`, so a variable assignment does not survive to the next
# line.
#
# The CAMERA runtime permission is pre-granted so the OS dialog can never
# block the run: `flutter test` installs the app itself, so the grant is
# retried in the background until the package exists. Without it the real
# camera scenario reports NotAllowedError and skips.
set -euo pipefail

PKG="org.codeberg.theoden8.webspace"

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# Best-effort now (app may already be installed from an earlier tier) and
# again in the background until the install lands.
adb -s "$device_id" shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true
(
  for _ in $(seq 1 60); do
    if adb -s "$device_id" shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1; then
      echo "camera tier: CAMERA permission granted to $PKG"
      break
    fi
    sleep 2
  done
) &

# Hard wall-clock cap: a webview mount can deadlock below the Dart timeout
# layer (same rationale as the white-screen tier).
exec timeout -k 30s 20m fvm flutter test \
  integration_test/camera_test.dart \
  -d "$device_id" --flavor fdebug
