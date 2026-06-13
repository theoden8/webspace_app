#!/usr/bin/env bash
# Verify the Rust adblock JNI bridge survived R8 in a release APK.
#
# Release builds shrink (android/app/proguard-rules.pro) to prune Flutter's
# dead Play Core path. Obfuscation is kept off and the native methods are
# pinned so the JNI entry points stay intact -- but a future regression
# (obfuscation flipped on, the keep rule dropped, R8 full-mode) would rename
# or strip them. That failure is invisible at build time and only surfaces
# at runtime as UnsatisfiedLinkError, so gate it in CI.
#
# The expected set is read from AdblockEngineNative.kt (every `external
# fun`), so adding or removing a native method needs no edit here. Each name
# must appear, unobfuscated, as a method of the bridge class in the DEX.
#
# Usage: scripts/check_jni_intact.sh <path-to-apk>

set -euo pipefail

APK="${1:?APK path required: scripts/check_jni_intact.sh <path-to-apk>}"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK not found: $APK" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KT="$REPO_ROOT/android/app/src/main/kotlin/org/codeberg/theoden8/webspace/AdblockEngineNative.kt"
CLASS="org.codeberg.theoden8.webspace.AdblockEngineNative"

if [[ ! -f "$KT" ]]; then
  echo "ERROR: AdblockEngineNative.kt not found at $KT" >&2
  exit 2
fi

# apkanalyzer ships with the Android SDK command-line tools (see
# check_no_gms.sh for the same resolution dance).
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

# Expected JNI methods = every `external fun <name>` in the bridge source.
mapfile -t EXPECTED < <(grep -oE 'external fun [A-Za-z0-9_]+' "$KT" \
  | awk '{print $3}' | sort -u)
if [[ ${#EXPECTED[@]} -eq 0 ]]; then
  echo "ERROR: no 'external fun' declarations found in $KT" >&2
  echo "If the JNI bridge moved, update this check." >&2
  exit 2
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

if ! DEX_TREE="$("$APKANALYZER" dex packages "$APK" 2>"$err_file")"; then
  echo "ERROR: apkanalyzer failed to read $APK" >&2
  cat "$err_file" >&2
  exit 2
fi

# Method (M) rows for the bridge class look like:
#   M d 1 1 12  org.codeberg.theoden8.webspace.AdblockEngineNative long nativeEngineNew(java.lang.String,boolean)
# Keep only M rows naming the class, then require "<name>(" so a param type
# of the same class on an unrelated method can't satisfy the match.
CLASS_METHODS="$(printf '%s\n' "$DEX_TREE" \
  | awk -v c="$CLASS" '$1 == "M" && index($0, c)')"

missing=()
for m in "${EXPECTED[@]}"; do
  if ! printf '%s\n' "$CLASS_METHODS" | grep -qE "[[:space:]]${m}\("; then
    missing+=("$m")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "JNI bridge broken in $APK -- native methods absent from the DEX:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "" >&2
  echo "R8 stripped or renamed the $CLASS entry points, so the Rust library" >&2
  echo "(Java_org_codeberg_theoden8_webspace_AdblockEngineNative_*) cannot" >&2
  echo "bind at runtime (UnsatisfiedLinkError). In proguard-rules.pro,"  >&2
  echo "obfuscation must stay off and the native-methods keep must remain." >&2
  exit 1
fi

echo "OK: $APK retains all ${#EXPECTED[@]} AdblockEngineNative JNI entry points."
