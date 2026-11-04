#!/usr/bin/env bash
# Assert the Tor pod's tor is a client build without tor's GPL-only parts
# (LICENSE-001). A tor configured with --enable-gpl links the proof-of-work
# solver, equix and hashx, which its BSD build leaves out. The pod downloads
# its tor.xcframework already built (download.sh), so the symbols are what can
# be read of how it was configured; a binary whose symbols cannot be read
# (no tor_run_main or tor_main) fails too, since it says nothing.
set -euo pipefail

pods="${1:?usage: verify_tor_framework.sh <Pods directory>}"
found=0
while IFS= read -r -d '' bin; do
  file "$bin" | grep -E -q 'Mach-O|ar archive' || continue
  found=$((found + 1))
  symbols=$(nm -a "$bin" 2>/dev/null || true)
  if ! grep -E -q '_tor_(run_)?main\b' <<<"$symbols"; then
    echo "::error::$bin has no readable tor_run_main or tor_main, so how it was built cannot be read" >&2
    exit 1
  fi
  if grep -E -q '_(equix|hashx)_[A-Za-z_]+' <<<"$symbols"; then
    echo "::error::$bin carries tor's GPL-only proof-of-work code (equix, hashx)" >&2
    exit 1
  fi
done < <(find "$pods/Tor" -path '*.xcframework/*' -type f -print0)
[ "$found" -gt 0 ] || { echo "::error::no tor binary under $pods/Tor" >&2; exit 1; }
echo "OK: $found tor binaries under $pods/Tor, none with equix or hashx"
