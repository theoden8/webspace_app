#!/usr/bin/env bash
# Android-emulator per-site proxy router tier (PROXY-013): the router
# against a real Android System WebView on the first connected
# device/emulator.
#
# This tier exists for one assumption that no other tier can reach.
# Chromium's `HttpAuthCache` is owned by the `HttpNetworkSession` and its
# proxy entries are not partitioned by `NetworkAnonymizationKey`, so the
# container profile boundary is the only thing keeping one site's proxy
# credential off another site's connections. A fake cannot answer whether
# that boundary holds; only a real System WebView with real profiles can.
# `proxy_router_attribution_test.dart` stands up two upstreams and fails
# if only one is ever reached, which is exactly what a shared auth cache
# would produce.
#
# Single entry point for the same reason as the white-screen tier:
# reactivecircus/android-emulator-runner executes each script line as a
# separate `sh -c`, so a variable assignment does not survive to the next
# line.
set -euo pipefail

device_id="${1:-$(adb devices | grep -w 'device' | head -1 | awk '{print $1}' || true)}"
if [ -z "$device_id" ]; then
  echo "ERROR: no connected Android device/emulator found" >&2
  adb devices >&2
  exit 1
fi

# Record the System WebView version. Router mode needs MULTI_PROFILE
# (WebView 110+), and the emulator images ship whatever WebView was current
# when the image was cut -- on api-34/google_apis that is older than 110, so
# the gate SKIPS and the job still goes green. Printing the version means a
# future reader can tell "the gate passed" from "the gate never ran" without
# re-deriving it from a [Container/debug] line.
echo "── System WebView on device ──"
adb -s "$device_id" shell dumpsys package com.google.android.webview \
  | grep -m1 versionName || echo "  (version not reported)"

# Hard wall-clock cap: a webview mount can deadlock below the Dart timeout
# layer (same rationale as the white-screen tier).
exec timeout -k 30s 20m fvm flutter test \
  integration_test/proxy_router_test.dart \
  integration_test/proxy_router_attribution_test.dart \
  -d "$device_id" --flavor fdebug
