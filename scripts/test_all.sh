#!/usr/bin/env bash
#
# Run the full local test suite: Dart (Flutter) + Node (JS shim).
# Exits non-zero on the first failure. Pass extra args through to
# `fvm flutter test` (e.g. `scripts/test_all.sh test/foo_test.dart`).
#
# Prereqs: fvm on PATH, npm install / npm ci done.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Dart tests (fvm flutter test)"
fvm flutter test "$@"

echo
echo "==> Node JS shim tests (npm run test:js)"
npm run test:js
