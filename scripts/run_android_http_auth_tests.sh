#!/usr/bin/env bash
# Android-emulator HTTP authentication tier (HTTPAUTH-007): a site's own
# 401 challenge against a real Android System WebView, where the callback
# carries no port and no is_proxy and so shares a path with the proxy
# router's 407.
#
# The Linux and macOS integration jobs run the same file against WPE WebKit
# and WKWebView.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/http_auth_test.dart 15
