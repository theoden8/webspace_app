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
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"

# Record the System WebView version. Router mode needs MULTI_PROFILE, and an
# emulator image ships whatever WebView was current when the image was cut, so
# the image decides whether this tier measures anything. The workflow pins
# api-35 / target `default`, which carries it; an older image (api-34
# google_apis shipped 113.0.5672.136) does NOT report the feature, and on one
# of those the gate SKIPS and the job still goes green. Printing the version
# means a future reader can tell "the gate passed" from "the gate never ran"
# rather than inferring it from a green tick.
bash "$(dirname "$0")/print_android_webview_version.sh" "$device_id"

run_tier integration_test/proxy_router_test.dart \
  integration_test/proxy_router_attribution_test.dart 20
