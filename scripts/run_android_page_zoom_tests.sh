#!/usr/bin/env bash
# Android-emulator page-zoom tier (BUG-008): the per-site zoom contract
# against a real Android System WebView on the first connected
# device/emulator.
#
# The Linux and macOS integration jobs run the same file against WPE and
# WKWebView, but only Android System WebView has the wide-viewport quirk
# that put every zoomed site on the 980px desktop layout, and it is
# reachable from no other engine.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/page_zoom_test.dart 15
