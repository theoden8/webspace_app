#!/usr/bin/env bash
# Perf-visibility trend (DEVTOOLS-013): boot the app on the emulator and switch
# between two loopback sites so the real AndroidX WebView emits its
# "Launch, from main():" and "Switch:" App-logs lines. The caller greps them
# out of the tier log into the device-numbers artifact. No gate: the emulator
# step invokes this with `|| true`, so a trend wobble never fails the build.
set -euo pipefail
. "$(dirname "$0")/lib/android_tier.sh"

pick_device "${1:-}"
# Five minutes is ample for an offline boot plus two switches; the cap only
# guards against a native webview deadlock below the Dart timeout layer.
run_tier integration_test/perf_timeline_test.dart 5
