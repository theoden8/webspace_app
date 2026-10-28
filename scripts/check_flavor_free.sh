#!/usr/bin/env bash
# Verify a release APK carries no trace of the flavor it was built as.
#
# F-Droid builds the fdroid flavor of a tag, while the release's APKs are
# fmain; F-Droid can ship the release's own signed APK only when the two are
# byte-identical apart from the signature. A flavor that reaches an entry
# makes that impossible and fails nothing else: Kotlin mangles an internal
# class member's JVM name with the variant (`localCdnResponse$app_fdroidRelease`),
# and naming the module only prefixes the variant. v1 signature files are
# skipped, since F-Droid's certificate names F-Droid.
#
# Usage: scripts/check_flavor_free.sh <path-to-apk> <flavor>

set -euo pipefail

APK="${1:?APK path required: scripts/check_flavor_free.sh <path-to-apk> <flavor>}"
FLAVOR="${2:?flavor required: scripts/check_flavor_free.sh <path-to-apk> <flavor>}"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK not found: $APK" >&2
  exit 2
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
unzip -q "$APK" -d "$dir"

if hits="$(grep -rlaF "$FLAVOR" "$dir" \
    --exclude='*.RSA' --exclude='*.SF' --exclude='*.EC' --exclude='*.DSA' \
    --exclude=MANIFEST.MF)"; then
  echo "$APK names its flavor '$FLAVOR' in:" >&2
  sed "s#^$dir/#  #" <<<"$hits" >&2
  echo "" >&2
  echo "Every flavor must build the same bytes, or F-Droid's build of a tag" >&2
  echo "cannot reproduce the release. A name ending in \$app_${FLAVOR}Release" >&2
  echo "is an internal member of a class: make it public or private." >&2
  exit 1
fi

echo "OK: $APK does not name its flavor '$FLAVOR'."
