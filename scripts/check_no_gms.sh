#!/usr/bin/env bash
# Verify that a built APK contains zero classes from forbidden namespaces
# (Google Mobile Services, Firebase, Play Services). Used both locally
# (test/gms_freedom_test.dart shells out to this) and in CI (after the
# F-Droid build step). The check operates on the *built* APK rather than
# scanning Gradle's dependency graph because:
#
#   - A clean-looking AAR can transitively pull GMS through its own deps.
#   - Vendored .jar / .aar files dropped into app/libs/ never appear in
#     `./gradlew app:dependencies`.
#   - Build-time codegen can compile GMS imports the source tree never
#     references directly.
#
# Only the APK reflects what actually ships.
#
# Usage: scripts/check_no_gms.sh <path-to-apk>

set -euo pipefail

APK="${1:?APK path required: scripts/check_no_gms.sh <path-to-apk>}"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK not found: $APK" >&2
  exit 2
fi

# apkanalyzer ships with the Android SDK command-line tools. In CI we set
# ANDROID_SDK_ROOT (or ANDROID_HOME) explicitly; locally most devs have
# it on PATH because they ran `flutter doctor`.
if ! command -v apkanalyzer >/dev/null 2>&1; then
  for candidate in \
    "${ANDROID_SDK_ROOT:-}/cmdline-tools/latest/bin/apkanalyzer" \
    "${ANDROID_HOME:-}/cmdline-tools/latest/bin/apkanalyzer" \
    "${ANDROID_SDK_ROOT:-}/tools/bin/apkanalyzer" \
    "${ANDROID_HOME:-}/tools/bin/apkanalyzer"; do
    if [[ -x "$candidate" ]]; then
      APKANALYZER="$candidate"
      break
    fi
  done
  if [[ -z "${APKANALYZER:-}" ]]; then
    echo "ERROR: apkanalyzer not found on PATH or in ANDROID_SDK_ROOT" >&2
    echo "Install Android command-line tools or set ANDROID_SDK_ROOT" >&2
    exit 2
  fi
else
  APKANALYZER="apkanalyzer"
fi

FORBIDDEN_REGEX='^(com\.google\.android\.gms|com\.google\.firebase|com\.google\.android\.play)'

# `apkanalyzer dex packages --defined-only` lists every package defined in
# the APK's DEX files (one column = "P" / "C" / "M" + name). We drop to
# the package column with awk and grep against the forbidden namespaces.
HITS="$("$APKANALYZER" dex packages --defined-only "$APK" 2>/dev/null \
  | awk '$1 == "P" {print $NF}' \
  | grep -E "$FORBIDDEN_REGEX" || true)"

if [[ -n "$HITS" ]]; then
  echo "GMS contamination detected in $APK:" >&2
  echo "$HITS" >&2
  echo "" >&2
  echo "WebSpace must run on devices without Google Mobile Services." >&2
  echo "Investigate which dependency pulled these in and remove or strip it." >&2
  exit 1
fi

echo "OK: $APK contains no GMS / Firebase / Play classes."
