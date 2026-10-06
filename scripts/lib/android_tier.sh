#!/usr/bin/env bash
# Sourced by scripts/run_android_*.sh, the emulator tiers.
#
# Each tier stays a single entry point: reactivecircus/android-emulator-runner
# runs every CI `script:` line as a separate `sh -c`, so a variable assignment
# does not survive to the next line, and a backslash-continued command is split
# mid-line (observed as flutter test loading a target literally named "\").

# Debug build type suffixes the applicationId; see android/app/build.gradle.
ANDROID_TIER_PKG="org.codeberg.theoden8.webspace.debug"

# Sets device_id to $1, or to the first connected device/emulator.
pick_device() {
  device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
  if [ -z "$device_id" ]; then
    echo "ERROR: no connected Android device/emulator found" >&2
    adb devices >&2
    exit 1
  fi
}

# Grants android.permission.$1 so an OS dialog cannot block the run. Best
# effort now (an earlier tier may have installed the app); `flutter test`
# installs it itself, so the grant is retried in the background until the
# package exists.
grant_when_installed() {
  local perm="android.permission.$1"
  adb -s "$device_id" shell pm grant "$ANDROID_TIER_PKG" "$perm" >/dev/null 2>&1 || true
  (
    for _ in $(seq 1 60); do
      if adb -s "$device_id" shell pm grant "$ANDROID_TIER_PKG" "$perm" >/dev/null 2>&1; then
        echo "$1 granted to $ANDROID_TIER_PKG"
        break
      fi
      sleep 2
    done
  ) &
}

# tier_test FILE... MINUTES [--grant PERM] [--define K=V]
#
# `flutter test` of FILE... on device_id under a hard wall-clock cap of
# MINUTES: a webview mount can deadlock below the Dart timeout layer, where no
# test-side deadline reaches it.
tier_test() {
  _tier_cmd "$@"
  "${tier_cmd[@]}"
}

# run_tier: tier_test in place of the script, so its status is the script's.
run_tier() {
  _tier_cmd "$@"
  exec "${tier_cmd[@]}"
}

_tier_cmd() {
  local files=() defines=() minutes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --grant) grant_when_installed "$2"; shift 2 ;;
      --define) defines+=("--dart-define=$2"); shift 2 ;;
      *.dart) files+=("$1"); shift ;;
      *) minutes="$1"; shift ;;
    esac
  done
  tier_cmd=(timeout -k 30s "${minutes}m" fvm flutter test "${files[@]}"
    -d "$device_id" --flavor fdebug ${defines[@]+"${defines[@]}"})
}
