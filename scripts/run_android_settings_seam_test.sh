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
#
# Single entry point for the same reason as the other emulator tiers:
# reactivecircus/android-emulator-runner executes each script line as a
# separate `sh -c`, so a variable assignment does not survive to the next line.
set -euo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# Record the System WebView version. The containerId half of the comparison
# only runs where the image's WebView reports MULTI_PROFILE, and an emulator
# image ships whatever WebView was current when it was cut. The test prints
# `containers=` either way (caution 8); this prints what decided it, so a
# reader can tell "the field was compared" from "the field was skipped"
# without inferring it from a green tick.
echo "── System WebView on device ──"
adb -s "$device_id" shell dumpsys package com.google.android.webview \
  | grep -m1 versionName || echo "  (version not reported)"

# Hard wall-clock cap: a webview mount can deadlock below the Dart timeout
# layer (same rationale as the white-screen tier).
exec timeout -k 30s 12m fvm flutter test \
  integration_test/settings_seam_test.dart \
  -d "$device_id" --flavor fdebug
