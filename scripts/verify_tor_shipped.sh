#!/usr/bin/env bash
# Assert the Linux bundle carries the built-in Tor (TOR-027) as
# linux/tor.cmake builds it: a tor that runs from lib/tor/ with the
# libraries it links beside it, its notices, no GeoIP table (LICENSE-002), a
# client build without tor's GPL-only modules (LICENSE-001), and the one
# pluggable transport the build makes, lyrebird, held by
# `go/iptproxy/build.sh check-lyrebird` to what that script checks it built
# (LICENSE-001, TOR-016). With WEBSPACE_LYREBIRD=none, the variable
# linux/tor.cmake builds without it by, no transport at all. The real-tor tier
# then drives them (test/managed_tor_real_test.dart with WS_TOR_BESIDE).
set -euo pipefail

bundle="${1:?usage: verify_tor_shipped.sh <bundle dir>}"
dir="$bundle/lib/tor"
root="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$dir/tor" ] || { echo "::error::$dir/tor is missing or not executable" >&2; exit 1; }
[ -f "$dir/docs/tor.txt" ] || { echo "::error::$dir/docs/tor.txt is missing" >&2; exit 1; }

tables=$(find "$bundle" -iname 'geoip*' -print)
if [ -n "$tables" ]; then
  echo "::error::the bundle carries GeoIP data, which is downloaded on the device (LICENSE-002):" >&2
  printf '%s\n' "$tables" >&2
  exit 1
fi

transports="$dir/pluggable_transports"
if [ "${WEBSPACE_LYREBIRD:-}" = none ]; then
  if [ -e "$transports" ]; then
    echo "::error::$transports ships, but WEBSPACE_LYREBIRD=none builds no transport:" >&2
    ls -la "$transports" >&2
    exit 1
  fi
else
  if [ ! -x "$transports/lyrebird" ]; then
    echo "::error::$transports/lyrebird is missing: linux/tor.cmake builds it with a go command," \
      "or WEBSPACE_LYREBIRD=none builds and checks without it" >&2
    exit 1
  fi
  others=$(find "$transports" -mindepth 1 ! -path "$transports/lyrebird")
  if [ -n "$others" ]; then
    echo "::error::$transports carries more than the lyrebird the build makes:" >&2
    printf '%s\n' "$others" >&2
    exit 1
  fi
  missing=$(ldd "$transports/lyrebird" | grep 'not found' || true)
  if [ -n "$missing" ]; then
    echo "::error::lyrebird links libraries the system lacks:" >&2
    printf '%s\n' "$missing" >&2
    exit 1
  fi
  sh "$root/go/iptproxy/build.sh" check-lyrebird "$dir"
fi

missing=$(LD_LIBRARY_PATH="$dir" ldd "$dir/tor" | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "::error::tor links libraries neither lib/tor nor the system has:" >&2
  printf '%s\n' "$missing" >&2
  exit 1
fi
for lib in "$dir"/*.so*; do
  [ -e "$lib" ] || continue
  if [ "$(find "$dir/docs" -name '*.txt' ! -name tor.txt ! -name lyrebird.txt | wc -l)" -eq 0 ]; then
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
