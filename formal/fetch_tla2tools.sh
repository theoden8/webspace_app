#!/usr/bin/env bash
# usage: fetch_tla2tools.sh <path>
# Fetches the TLC jar to <path> unless a file is already there; every script
# that runs TLC gets it here.
#
# Retried: a single 504 from GitHub's release-asset CDN otherwise takes the
# whole validate job down before a single model runs. Observed four times
# across three PRs in one afternoon (tla2tools twice, the Gradle
# distribution, fvm).
#
# `latest` rather than a pinned tag, which is a reproducibility hole this
# repo would not otherwise accept. Pinning needs the current tag; resolve it
# and switch this to
# `https://github.com/tlaplus/tlaplus/releases/download/<tag>/tla2tools.jar`.
set -euo pipefail
JAR="${1:?usage: fetch_tla2tools.sh <path>}"
[ ! -f "$JAR" ] || exit 0
echo "Fetching tla2tools.jar…"
curl -fsSL --retry 4 --retry-delay 2 -o "$JAR" \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
