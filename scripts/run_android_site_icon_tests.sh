#!/usr/bin/env bash
# Android-emulator site-icon tier (ICON-009/010/011/014): which page icon a
# real Android System WebView hands to `onReceivedIcon`, and which of those
# the app takes, on the first connected device/emulator. A second run turns
# on Site icons only, under which Android fetches the declared links instead
# (ICON-013) and ignores the callback.
#
# Only Android WebView has the callback, so no other tier reaches this path.
# The macOS integration job runs the same file for the fetch path.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
tier_test integration_test/site_icon_test.dart 15
run_tier integration_test/site_icon_test.dart 15 --define WS_SITE_ICONS_ONLY=true
