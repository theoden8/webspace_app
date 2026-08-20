#!/usr/bin/env bash
# Regenerates everything the Claude Design project shows, from the current
# working tree: gallery build -> card screenshots -> uploadable bundle.
#
# The upload itself is a DesignSync call, which only an agent session can make;
# see "Refresh requests" in tool/design_gallery/CLAUDE.md.

set -euo pipefail
cd "$(dirname "$0")/.."

scripts/design_web.sh gallery
node tool/design_gallery/shoot.js
node tool/design_gallery/bundle.js

echo
echo "bundle ready: build/design_bundle (built from $(git rev-parse --short HEAD))"
