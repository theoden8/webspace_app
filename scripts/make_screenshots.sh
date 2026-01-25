#!/usr/bin/env bash

set -ex

# Usage: ./scripts/make_screenshots.sh [android|ios]
# If no argument provided, will try to auto-detect from connected device

TARGET_PLATFORM="${1:-}"

# Auto-detect platform if not provided
if [ -z "$TARGET_PLATFORM" ]; then
  # Check if an iOS simulator or device is connected
  if flutter devices | grep -qi "ios\|iphone\|ipad"; then
    TARGET_PLATFORM="ios"
  elif flutter devices | grep -qi "android"; then
    TARGET_PLATFORM="android"
  else
    echo "Warning: Could not auto-detect platform. Specify android or ios as argument."
    TARGET_PLATFORM=""
  fi
fi

echo "Target platform: ${TARGET_PLATFORM:-unspecified}"

TARGET_PLATFORM="$TARGET_PLATFORM" fvm flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain

