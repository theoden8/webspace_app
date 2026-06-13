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

# `apkanalyzer dex packages` lists every package (P), class (C) and method
# (M) node in the APK's DEX files, each tagged defined ("d") or referenced
# ("r"). We deliberately do NOT pass --defined-only: F-Droid's scanner
# rejects an APK that merely *references* a forbidden class, and Flutter's
# embedding references com.google.android.play.core.* from its
# deferred-components code path (PlayStoreDeferredComponentManager). With
# R8 shrinking disabled (-dontshrink in proguard-rules.pro) those
# references survive into the dex even though the app never instantiates
# that manager — so a defined-only scan reports a clean APK that F-Droid
# then bounces. Scan references too, matching F-Droid's contract.
#
# Match P and C rows (their name is the last field); M rows carry a method
# signature with embedded spaces, but every forbidden class already shows
# up as a C row, so they add nothing.
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

if ! DEX_TREE="$("$APKANALYZER" dex packages "$APK" 2>"$err_file")"; then
  echo "ERROR: apkanalyzer failed to read $APK" >&2
  cat "$err_file" >&2
  exit 2
fi

HITS="$(printf '%s\n' "$DEX_TREE" \
  | awk '$1 == "P" || $1 == "C" { print $NF }' \
  | grep -E "$FORBIDDEN_REGEX" \
  | sort -u || true)"

if [[ -n "$HITS" ]]; then
  echo "GMS contamination detected in $APK:" >&2
  echo "$HITS" >&2
  echo "" >&2
  echo "WebSpace must run on devices without Google Mobile Services." >&2
  echo "These classes are defined or referenced in the shipped DEX." >&2
  echo "Investigate which dependency pulled these in and remove or strip it." >&2
  exit 1
fi

echo "OK: $APK contains no GMS / Firebase / Play classes."
