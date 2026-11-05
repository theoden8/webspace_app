#!/usr/bin/env bash
# Runs tool/swift_tests: the Runner's plain Swift under XCTest (CB-023's
# load counting among it). No Apple SDK needed. Skips (0) without a Swift
# toolchain locally; under CI=true a missing toolchain fails, so the tier
# cannot silently stop being one.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v swift >/dev/null 2>&1; then
  if [ "${CI:-}" = true ]; then
    echo "::error::swift_tests: no swift on PATH" >&2
    exit 1
  fi
  echo "swift_tests: no swift on PATH, skipping"
  exit 0
fi
swift test --package-path "$here" --scratch-path "${TMPDIR:-/tmp}/webspace-swift-tests"
