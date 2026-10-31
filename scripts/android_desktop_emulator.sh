#!/usr/bin/env bash
# The Android desktop emulator (INTEG-018): installs the image, creates the
# AVD, boots it and runs the command it is given once the image's input
# service is up, then stops it. Not reactivecircus/android-emulator-runner,
# which presses a key the moment sys.boot_completed reads 1; on this image's
# cold boot the input service registers after that, and the press fails the
# step before any test runs.
#
#   bash scripts/android_desktop_emulator.sh <command> [args...]
set -euo pipefail

: "${ANDROID_HOME:?names the Android SDK}"
image='system-images;android-37.1;android-desktop;x86_64'
avd=desktop
serial=emulator-5554
log="${RUNNER_TEMP:-/tmp}/android-desktop-emulator.log"

# The desktop image is published on the beta channel, and wants that
# channel's emulator.
sdkmanager --channel=1 --install emulator platform-tools "$image" >/dev/null
echo no | avdmanager create avd --force --name "$avd" \
  --abi android-desktop/x86_64 --package "$image" --device desktop_small >/dev/null
printf 'hw.keyboard=yes\ndisk.dataPartition.size=4096M\n' \
  >> "$HOME/.android/avd/$avd.avd/config.ini"

"$ANDROID_HOME/emulator/emulator" -port 5554 -avd "$avd" -no-snapshot \
  -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim >"$log" 2>&1 &
trap 'adb -s "$serial" emu kill >/dev/null 2>&1 || true' EXIT

adb -s "$serial" wait-for-device

ready() {
  local booted input settings
  booted=$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null || true)
  input=$(adb -s "$serial" shell service check input 2>/dev/null || true)
  settings=$(adb -s "$serial" shell service check settings 2>/dev/null || true)
  [ "${booted//$'\r'/}" = 1 ] && grep -q ': found' <<<"$input" &&
    grep -q ': found' <<<"$settings"
}

# The settings service has been seen to go away just after the image
# reported booted (a broken pipe to it), so the image has to stay ready for
# a while before it is asked anything.
steady=0
for _ in $(seq 1 300); do
  if ready; then steady=$((steady + 1)); else steady=0; fi
  [ "$steady" -ge 10 ] && break
  sleep 2
done
if [ "$steady" -lt 10 ]; then
  echo "ERROR: the desktop emulator did not settle" >&2
  tail -40 "$log" >&2
  exit 1
fi

retry() {
  for _ in $(seq 1 15); do
    "$@" && return 0
    sleep 2
  done
  "$@"
}
for scale in window_animation_scale transition_animation_scale animator_duration_scale; do
  retry adb -s "$serial" shell settings put global "$scale" 0.0
done
retry adb -s "$serial" shell settings put global hide_error_dialogs 1
retry adb -s "$serial" shell settings put secure show_ime_with_hard_keyboard 0

"$@"
