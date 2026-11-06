#!/usr/bin/env bash
# Android-emulator block accounting tier (CB-012, DNS-014): a page whose every
# request is declared, counted by the native interceptor, held to what a
# loopback server saw arrive. The desktop jobs run the same test on WebKit.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
run_tier integration_test/block_accounting_test.dart 10
