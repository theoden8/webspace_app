#!/usr/bin/env bash
# Sourced by scripts/run_android_*.sh, the emulator tiers.
#
# Each tier stays a single entry point: reactivecircus/android-emulator-runner
# runs every CI `script:` line as a separate `sh -c`, so a variable assignment
# does not survive to the next line, and a backslash-continued command is split
# mid-line (observed as flutter test loading a target literally named "\").

# Debug build type suffixes the applicationId; see android/app/build.gradle.
ANDROID_TIER_PKG="org.codeberg.theoden8.webspace.debug"
ANDROID_TIER_BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/integration_bundle.sh"

# Sets device_id to $1, or to the first connected device/emulator, and points
# adb and scripts/integration_bundle.sh at it.
pick_device() {
  device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
  if [ -z "$device_id" ]; then
    echo "ERROR: no connected Android device/emulator found" >&2
    adb devices >&2
    exit 1
  fi
  export ANDROID_SERIAL="$device_id"
}

# Grants android.permission.$1 so an OS dialog cannot block the run. Best
# effort now (an earlier tier may have installed the app); the launch installs
# it itself, so the grant is retried in the background until the package
# exists.
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

# tier_test FILE... MINUTES [--grant PERM] [--input KEY=VALUE]
#
# Each FILE on device_id under a hard wall-clock cap of MINUTES: a webview
# mount can deadlock below the Dart timeout layer, where no test-side deadline
# reaches it. A file runs from the app scripts/integration_bundle.sh built for
# every file at once, told each input at launch (TierInput). Each launch
# installs the app and uninstalls it after, so each PERM is granted again
# before each file.
tier_test() {
  local files=() grants=() inputs=() minutes="" status=0 rc f perm
  while [ $# -gt 0 ]; do
    case "$1" in
      --grant) grants+=("$2"); shift 2 ;;
      --input) inputs+=("$2"); shift 2 ;;
      *.dart) files+=("$1"); shift ;;
      *) minutes="$1"; shift ;;
    esac
  done
  for f in "${files[@]}"; do
    echo "::group::$f"
    for perm in ${grants[@]+"${grants[@]}"}; do grant_when_installed "$perm"; done
    rc=0
    timeout -k 30s "${minutes}m" bash "$ANDROID_TIER_BUNDLE" run android "$f" \
      "${RUNNER_TEMP:-/tmp}/tier-$(basename "$f").log" ${inputs[@]+"${inputs[@]}"} || rc=$?
    if [ "$rc" -ne 0 ]; then
      status=$rc
      if [ "$rc" -eq 124 ]; then echo "::error::$f killed after ${minutes}m wall-clock cap"; fi
    fi
    echo "::endgroup::"
  done
  return "$status"
}

# run_tier: tier_test as the script's last word, so its status is the script's.
run_tier() {
  tier_test "$@" || exit
  exit 0
}
