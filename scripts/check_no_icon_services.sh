#!/usr/bin/env bash
# Verify that a built F-Droid APK cannot ask Google's or DuckDuckGo's favicon
# services (ICON-012 in openspec/specs/icon-fetching/spec.md). F-Droid lists
# them as a NonFreeNet anti-feature.
#
# The gate in lib/services/icon_service.dart is a compile-time constant, so
# the release compiler drops both services from the fdroid build and their
# hosts never reach libapp.so. Scanning the built APK covers the whole chain:
# `--flavor fdroid` setting FLUTTER_APP_FLAVOR, the gate itself, and any call
# site added later outside it.
#
# A string the scraper keeps must be present, so a change in how the AOT
# snapshot stores strings fails here instead of passing on a blind grep.
#
# Usage: scripts/check_no_icon_services.sh <path-to-apk>

set -euo pipefail

APK="${1:?APK path required: scripts/check_no_icon_services.sh <path-to-apk>}"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK not found: $APK" >&2
  exit 2
fi

FORBIDDEN=('icons.duckduckgo.com' 'google.com/s2/favicons')
CONTROL='/favicon.ico'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! unzip -q -o "$APK" 'lib/*/libapp.so' -d "$tmp"; then
  echo "ERROR: no lib/*/libapp.so in $APK" >&2
  exit 2
fi

found=0
status=0
while IFS= read -r so; do
  found=1
  abi="${so#"$tmp"/}"
  if ! grep -a -q -F "$CONTROL" "$so"; then
    echo "ERROR: control string '$CONTROL' missing from $abi;" \
      "Dart strings are not readable there, so this check proves nothing" >&2
    exit 2
  fi
  for s in "${FORBIDDEN[@]}"; do
    if grep -a -q -F "$s" "$so"; then
      echo "Third-party icon service '$s' is compiled into $abi of $APK" >&2
      status=1
    fi
  done
done < <(find "$tmp" -name libapp.so)

if [[ $found -eq 0 ]]; then
  echo "ERROR: no libapp.so extracted from $APK" >&2
  exit 2
fi

if [[ $status -ne 0 ]]; then
  echo "" >&2
  echo "The F-Droid build must not ask Google or DuckDuckGo for icons" >&2
  echo "(NonFreeNet). Check that every use of them in" >&2
  echo "lib/services/icon_service.dart sits behind isFdroidFlavor." >&2
  exit 1
fi

echo "OK: $APK asks no third-party icon service."
