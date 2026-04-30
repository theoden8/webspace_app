#!/usr/bin/env bash
#
# Run the full local test suite: Dart (Flutter) + Node (JS shim) +
# optional browser tests (Puppeteer + headless Chromium). Exits
# non-zero on the first failure. Pass extra args through to
# `fvm flutter test` (e.g. `scripts/test_all.sh test/foo_test.dart`).
#
# Prereqs: fvm on PATH, npm install / npm ci done. Browser tests
# additionally need `npx puppeteer browsers install chromium` to have
# downloaded a headless build under ~/.cache/puppeteer (or
# /opt/pw-browsers, or wherever PUPPETEER_CACHE_DIR points).
#
# Browser tests are run only when explicitly requested
# (WEBSPACE_RUN_BROWSER_TESTS=1) — they download ~170 MB of Chromium
# on first install and add ~2-3s to the suite. They auto-skip when
# Chromium can't launch, so the rest of the suite is robust to a
# missing browser.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Dart tests (fvm flutter test)"
fvm flutter test "$@"

echo
echo "==> Node JS shim tests (npm run test:js)"
npm run test:js

if [ "${WEBSPACE_RUN_BROWSER_TESTS:-0}" = "1" ]; then
  echo
  echo "==> Browser tests (npm run test:browser)"
  npm run test:browser
else
  echo
  echo "==> Skipping browser tests (set WEBSPACE_RUN_BROWSER_TESTS=1 to enable)"
fi
