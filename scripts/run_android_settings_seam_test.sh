#!/usr/bin/env bash
# The per-site settings seam against a real Android System WebView (BUG-014).
#
# The seam guard compares every per-site field Dart sends against what the
# engine actually holds, and the engine has to be a real one: Android parses
# `InAppWebViewSettings` with an explicit `switch`, so a field nobody wired is
# dropped as silently as one Apple's reflective parser cannot see. No fake
# answers that question.
#
# Separate from the router tier on purpose: a router failure and a dropped
# field are different findings, and sharing one script's wall-clock cap would
# let a hung router arm swallow this one.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"

# Record the System WebView version. The containerId half of the comparison
# only runs where the image's WebView reports MULTI_PROFILE, and an emulator
# image ships whatever WebView was current when it was cut. The test prints
# `containers=` either way (caution 8); this prints what decided it, so a
# reader can tell "the field was compared" from "the field was skipped"
# without inferring it from a green tick.
bash "$(dirname "$0")/print_android_webview_version.sh" "$device_id"

run_tier integration_test/settings_seam_test.dart 12
