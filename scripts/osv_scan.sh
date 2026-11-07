#!/usr/bin/env bash
# Every lockfile git tracks, checked against the OSV vulnerability database
# (osv.dev, which carries the GitHub, RustSec and npm advisories and their
# CVE aliases). An advisory nobody has accepted, with the reason it cannot
# reach the app, fails; so does an accepted one no longer reported
# (tool/osv_check.js, docs/security/accepted_advisories.tsv).
#
# Builds osv-scanner from the Go module proxy at a pinned version, so it needs
# Go and network: CI's validate-sources job has both.
set -euo pipefail

cd "$(dirname "$0")/.."

version=v2.7.0
bin="${RUNNER_TEMP:-$(mktemp -d)}/osv-scanner-$version"
if [ ! -x "$bin/osv-scanner" ]; then
  GOBIN="$bin" go install "github.com/google/osv-scanner/v2/cmd/osv-scanner@$version"
fi

lockfiles=()
while IFS= read -r f; do
  lockfiles+=(-L "$f")
done < <(git ls-files '*pubspec.lock' '*Cargo.lock' '*package-lock.json')
[ "${#lockfiles[@]}" -gt 0 ] || { echo "no lockfiles tracked" >&2; exit 1; }

report="$(mktemp)"
# 0: nothing found; 1: advisories found, which the check below judges;
# anything else is the scanner failing, which is not a clean result.
status=0
"$bin/osv-scanner" scan source "${lockfiles[@]}" --format json > "$report" || status=$?
if [ "$status" -gt 1 ]; then
  echo "osv-scanner failed with status $status" >&2
  exit "$status"
fi

node tool/osv_check.js "$report" docs/security/accepted_advisories.tsv
