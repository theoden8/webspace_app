#!/usr/bin/env bash
# Runs the Linux egress relay (network-interface NETIF-002 to NETIF-007,
# linux/egress_relay_core.cc) over real sockets, driving it as a site's
# webview does (harness.cc), with a stand-in for systemd-resolved on a bus of
# its own (mock_resolved.c). The Dart tiers never reach this code, and the
# Linux build only compiles it.
#
# Two veth links, A and B, with a route to 198.51.100.0/24 by B only: a
# connection the relay binds to A must leave by A, which the neighbour table
# names. That needs CAP_NET_ADMIN, which CI's Linux container has.
#
# It then builds the source with each planted mistake below and fails unless
# the harness catches every one.
#
# Needs a C and C++ compiler, pkg-config with gio-2.0, dbus-run-session and
# ip. Skips (0) when any is missing, and fails instead with CI=true, so in CI
# it is a gate and not a skip.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
here="$root/test/linux/egress_relay"

missing() {
  if [ "${CI:-}" = "true" ]; then
    echo "egress_relay check: $1" >&2
    exit 1
  fi
  echo "egress_relay check: $1, skipping"
  exit 0
}

if [ -z "${WS_EGRESS_BUS:-}" ]; then
  for tool in cc pkg-config dbus-run-session ip; do
    command -v "$tool" > /dev/null || missing "$tool is missing"
  done
  command -v clang++ > /dev/null || command -v g++ > /dev/null || missing "a C++ compiler is missing"
  pkg-config --exists gio-2.0 || missing "gio-2.0 is missing"
  # The rest runs on a session bus of its own, which only the stand-in owns.
  exec env WS_EGRESS_BUS=1 dbus-run-session -- "$0" "$@"
fi

work="$(mktemp -d /tmp/ws-egress.XXXXXX)"
link_a=ws-ega
link_b=ws-egb
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null || true; done
  wait 2> /dev/null || true
  ip link del "$link_a" 2> /dev/null || true
  ip link del "$link_b" 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cxx="$(command -v clang++ || command -v g++)"
flags=(-std=c++14 -Wall -Werror -O1 -pthread)
deps=$(pkg-config --cflags --libs gio-2.0)

cc -O1 -o "$work/mock_resolved" "$here/mock_resolved.c" $(pkg-config --cflags --libs gio-2.0)
build() {
  local source="$1" out="$2"
  "$cxx" "${flags[@]}" -o "$out" "$here/harness.cc" \
    -DEGRESS_SOURCE="\"$source\"" -I"$root/linux" $deps
}
build "$root/linux/egress_relay_core.cc" "$work/harness"

"$work/mock_resolved" > "$work/resolved.log" 2>&1 & pids+=($!)
sleep 0.5

links=false
if ip link add "$link_a" type veth peer name "$link_a-p" 2> /dev/null; then
  ip link add "$link_b" type veth peer name "$link_b-p"
  for l in "$link_a" "$link_a-p" "$link_b" "$link_b-p"; do ip link set "$l" up; done
  ip addr add 10.211.1.1/24 dev "$link_a"
  ip addr add 10.211.2.1/24 dev "$link_b"
  ip route add 198.51.100.0/24 dev "$link_b"
  links=true
elif [ "${CI:-}" = "true" ]; then
  echo "egress_relay check: no veth links without CAP_NET_ADMIN" >&2
  exit 1
fi

# Runs [harness] in [scenario]; its exit status.
run() {
  local harness="$1" scenario="$2"
  case "$scenario" in
    leaves_by | down)
      ip neigh flush to 198.51.100.7 2> /dev/null || true
      if [ "$scenario" = down ]; then ip link set "$link_a" down; fi
      local status=0
      WS_LINK_A="$link_a" WS_LINK_B="$link_b" timeout 30 "$harness" "$scenario" || status=$?
      ip link set "$link_a" up
      return "$status"
      ;;
    vectors)
      WS_EGRESS_VECTORS="$root/test/fixtures/egress_credentials.tsv" timeout 30 "$harness" "$scenario"
      ;;
    no_resolver)
      DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/no-bus" timeout 30 "$harness" "$scenario"
      ;;
    *)
      DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" timeout 30 "$harness" "$scenario"
      ;;
  esac
}

# What each scenario verifies: vectors and direct, NETIF-004 (the credential
# names the route, and the relay carries it); bad_secret, NETIF-004 and
# LEAK-009 (an unattributable caller is refused); absent and down, NETIF-002
# (no route while the interface is gone); leaves_by, NETIF-003 (bound to the
# device, never by the source address); dns_on_link, no_resolver and onion,
# NETIF-007 (names only through the link's own servers); socks_upstream and
# http_upstream, NETIF-005 (a proxy dialled over the interface).
scenarios=(vectors direct bad_secret absent dns_on_link no_resolver onion socks_upstream http_upstream)
if [ "$links" = true ]; then
  scenarios+=(leaves_by down)
else
  echo "egress_relay check: no veth links here, the leaves_by and down scenarios skip"
fi
failed=0
for scenario in "${scenarios[@]}"; do
  echo "== $scenario"
  run "$work/harness" "$scenario" || failed=1
done
[ "$failed" = 0 ] || { echo "egress_relay check: FAILED" >&2; exit 1; }

# Each planted mistake: a name, the scenario that must catch it, and the sed
# script that plants it.
plant() {
  local name="$1" scenario="$2"
  shift 2
  if [ "$links" != true ] && { [ "$scenario" = leaves_by ] || [ "$scenario" = down ]; }; then
    echo "== planted: $name ($scenario) skips without veth links"
    return 0
  fi
  local planted="$work/$name.cc"
  sed "$@" "$root/linux/egress_relay_core.cc" > "$planted"
  if cmp -s "$planted" "$root/linux/egress_relay_core.cc"; then
    echo "egress_relay check: the edit for $name no longer applies" >&2
    exit 1
  fi
  build "$planted" "$work/harness_$name"
  echo "== planted: $name ($scenario)"
  if run "$work/harness_$name" "$scenario" > "$work/$name.log" 2>&1; then
    cat "$work/$name.log"
    echo "egress_relay check: the harness missed the planted $name" >&2
    exit 1
  fi
  grep '^FAIL' "$work/$name.log" | sed 's/^/  caught: /'
}

bind_line='^  if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, link.c_str(),$'
plant unbound leaves_by \
  -e "s/$bind_line/  if (false \&\& setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, link.c_str(),/"
plant source_bind leaves_by \
  -e "/^namespace {\$/r $here/source_bind.inc" \
  -e "s/$bind_line/  if (BindSource(fd, link) != 0 \&\& setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, link.c_str(),/"
plant any_secret bad_secret \
  -e 's/^  if (!SecretMatches(secret, given)) return false;/  if (!SecretMatches(secret, given) \&\& false) return false;/'
plant any_link_dns dns_on_link \
  -e 's/g_variant_new("(isit)", static_cast<gint32>(link.index), name.c_str(),/g_variant_new("(isit)", 0, name.c_str(),/'
plant percent_kept vectors \
  -e 's/^    route->password = Unescape(password.substr(dot + 1));/    route->password = password.substr(dot + 1); (void)\&Unescape;/'
plant http_as_socks http_upstream \
  -e 's/^  if (route.kind == UpstreamKind::kHttp) {/  if (route.kind == UpstreamKind::kHttp \&\& false) {/'
plant onion_direct onion \
  -e 's/^  } else if (IsOnion(host)) {/  } else if (false \&\& IsOnion(host)) {/'
echo "egress_relay check: passed, and caught every planted mistake it could run"
