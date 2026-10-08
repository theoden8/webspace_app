#!/usr/bin/env bash
# Android-emulator LocalCDN tier (LCDN-007): a site's own LocalCDN choice
# decides whether its CDN sub-resources come from the app-wide cache. Only
# Android intercepts sub-resources, so no other engine can run it.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/localcdn_per_site_test.dart 10
