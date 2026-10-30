#!/usr/bin/env bash
# Assert the Linux bundle carries the built-in Tor (TOR-027) and no GeoIP
# table (LICENSE-002): tor, the libraries it links, lyrebird and their
# notices at lib/tor/, as linux/tor_bundle.cmake installs them, and a tor
# that runs from there. The real-tor tier then drives it
# (test/managed_tor_real_test.dart with WS_TOR_BESIDE).
set -euo pipefail

bundle="${1:?usage: verify_tor_shipped.sh <bundle dir>}"
dir="$bundle/lib/tor"

for f in tor pluggable_transports/lyrebird; do
  [ -x "$dir/$f" ] || { echo "::error::$dir/$f is missing or not executable" >&2; exit 1; }
done
for f in libevent-2.1.so.7 libssl.so.3 libcrypto.so.3 docs/tor.txt docs/lyrebird.txt; do
  [ -f "$dir/$f" ] || { echo "::error::$dir/$f is missing" >&2; exit 1; }
done

tables=$(find "$bundle" -iname 'geoip*' -print)
if [ -n "$tables" ]; then
  echo "::error::the bundle carries GeoIP data, which is downloaded on the device (LICENSE-002):" >&2
  printf '%s\n' "$tables" >&2
  exit 1
fi

version=$(LD_LIBRARY_PATH="$dir" "$dir/tor" --version | head -1)
echo "OK: $version at $dir"
