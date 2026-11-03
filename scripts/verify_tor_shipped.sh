#!/usr/bin/env bash
# Assert the Linux bundle carries the built-in Tor (TOR-027) as
# linux/tor.cmake builds it: a tor that runs from lib/tor/ with the
# libraries it links beside it, its notices, no GeoIP table (LICENSE-002), no
# pluggable transport, and a client build without tor's GPL-only modules
# (LICENSE-001). The real-tor tier then drives it
# (test/managed_tor_real_test.dart with WS_TOR_BESIDE).
set -euo pipefail

bundle="${1:?usage: verify_tor_shipped.sh <bundle dir>}"
dir="$bundle/lib/tor"

[ -x "$dir/tor" ] || { echo "::error::$dir/tor is missing or not executable" >&2; exit 1; }
[ -f "$dir/docs/tor.txt" ] || { echo "::error::$dir/docs/tor.txt is missing" >&2; exit 1; }

tables=$(find "$bundle" -iname 'geoip*' -print)
if [ -n "$tables" ]; then
  echo "::error::the bundle carries GeoIP data, which is downloaded on the device (LICENSE-002):" >&2
  printf '%s\n' "$tables" >&2
  exit 1
fi

if [ -e "$dir/pluggable_transports" ]; then
  echo "::error::$dir/pluggable_transports ships, but the build ships no transport:" >&2
  ls -la "$dir/pluggable_transports" >&2
  exit 1
fi

missing=$(LD_LIBRARY_PATH="$dir" ldd "$dir/tor" | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "::error::tor links libraries neither lib/tor nor the system has:" >&2
  printf '%s\n' "$missing" >&2
  exit 1
fi
for lib in "$dir"/*.so*; do
  [ -e "$lib" ] || continue
  if [ "$(find "$dir/docs" -name '*.txt' ! -name tor.txt | wc -l)" -eq 0 ]; then
    echo "::error::$lib ships with no notice in $dir/docs" >&2
    exit 1
  fi
done

# tor builds its proof-of-work module only with --enable-gpl, which makes the
# program GPL.
modules=$(LD_LIBRARY_PATH="$dir" "$dir/tor" --list-modules)
if grep -qx 'pow: yes' <<<"$modules"; then
  echo "::error::$dir/tor was configured with --enable-gpl:" >&2
  printf '%s\n' "$modules" >&2
  exit 1
fi

version=$(LD_LIBRARY_PATH="$dir" "$dir/tor" --version | head -1)
echo "OK: $version at $dir"
printf '%s\n' "$modules"
