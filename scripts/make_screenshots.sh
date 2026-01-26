#!/usr/bin/env bash

set -ex

# Set SCREENSHOT_DIR to control where screenshots are saved.
# The test_driver does NOT detect target platform - it runs on the host machine.
# Fastlane lanes set this automatically; for manual runs, set it explicitly.
SCREENSHOT_DIR="${SCREENSHOT_DIR:-screenshots}" fvm flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain

