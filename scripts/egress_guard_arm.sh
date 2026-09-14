#!/usr/bin/env bash
# Arm the CI egress guard (INTEG-016) for the Linux integration tier.
#
# Deny-by-default outbound: loopback stays reachable (fixture servers, the
# Dart VM service, the proxy relay), everything else is steered into
# `egress_recorder.py` and closed. A recording proxy could not do this job
# -- the leak class the ip-leakage spec is about (LEAK-002, LEAK-006) is
# traffic that ignores the proxy config, so the gate has to sit below it.
#
# Two rulesets, best first:
#
#   redirect -- an nftables nat/output hook rewrites the destination to the
#     recorder, which reads SO_ORIGINAL_DST and the first bytes. Full
#     attribution: address, port, and the SNI or Host that names the site.
#   reject   -- installed when the nat chain cannot be created (the nat
#     hook needs modules the container may not be able to autoload). Only
#     counts what was blocked. Names still arrive, because resolv.conf
#     points at the recorder either way.
#
# Run AFTER every provisioning step (apt, fvm install, pub get, precache):
# from here on the runner itself has no network either, and a toolchain
# that reaches out mid-suite becomes a finding rather than a download.
#
# Idempotent. Pair with egress_guard_disarm.sh from an `if: always()` step;
# leaving this armed takes the network away from later steps.
set -euo pipefail

STATE_DIR="${WS_EGRESS_STATE:-/tmp/ws-egress}"
TCP_PORT="${WS_EGRESS_TCP_PORT:-19531}"
UDP_PORT="${WS_EGRESS_UDP_PORT:-19532}"
DNS_PORT=53
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" != "0" ]; then
  echo "egress-guard: needs root (CAP_NET_ADMIN) to install the ruleset" >&2
  exit 1
fi
command -v nft >/dev/null || { echo "egress-guard: nft not installed" >&2; exit 1; }

mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR/ready" "$STATE_DIR/mode"

# Docker bind-mounts /etc/resolv.conf, so rewrite it in place -- replacing
# the inode fails with EBUSY.
if [ ! -f "$STATE_DIR/resolv.conf.orig" ]; then
  cp /etc/resolv.conf "$STATE_DIR/resolv.conf.orig"
fi
printf 'nameserver 127.0.0.1\noptions timeout:1 attempts:1\n' > /etc/resolv.conf

nohup python3 "$HERE/egress_recorder.py" \
  --log "$STATE_DIR/egress.jsonl" \
  --tcp-port "$TCP_PORT" --udp-port "$UDP_PORT" --dns-port "$DNS_PORT" \
  --ready-file "$STATE_DIR/ready" \
  > "$STATE_DIR/recorder.log" 2>&1 &
echo $! > "$STATE_DIR/recorder.pid"

for _ in $(seq 1 50); do
  [ -f "$STATE_DIR/ready" ] && break
  sleep 0.1
done
if [ ! -f "$STATE_DIR/ready" ]; then
  echo "egress-guard: recorder did not come up" >&2
  cat "$STATE_DIR/recorder.log" >&2 || true
  exit 1
fi

nft_redirect() {
  nft -f - <<NFT
table ip ws_egress
delete table ip ws_egress
table ip ws_egress {
  chain output {
    type nat hook output priority dstnat; policy accept;
    ip daddr 127.0.0.0/8 return
    meta l4proto udp udp dport 53 redirect to :$DNS_PORT
    meta l4proto tcp redirect to :$TCP_PORT
    meta l4proto udp redirect to :$UDP_PORT
  }
}
NFT
}

nft_redirect6() {
  nft -f - <<NFT
table ip6 ws_egress
delete table ip6 ws_egress
table ip6 ws_egress {
  chain output {
    type nat hook output priority dstnat; policy accept;
    ip6 daddr ::1 return
    meta l4proto udp udp dport 53 redirect to :$DNS_PORT
    meta l4proto tcp redirect to :$TCP_PORT
    meta l4proto udp redirect to :$UDP_PORT
  }
}
NFT
}

nft_reject() {
  nft -f - <<'NFT'
table inet ws_egress_filter
delete table inet ws_egress_filter
table inet ws_egress_filter {
  counter blocked_tcp { }
  counter blocked_udp { }
  chain output {
    type filter hook output priority filter; policy accept;
    ip daddr 127.0.0.0/8 return
    ip6 daddr ::1 return
    # icmpx, not `reject with tcp reset`: a reset generated in the output
    # hook is aimed at the remote and never reaches the local socket, so
    # the connect sits there until its own timeout (measured: 4s vs 10ms).
    # A suite whose per-test cap is 12 minutes cannot afford that per
    # blocked fetch.
    meta l4proto tcp counter name blocked_tcp reject with icmpx port-unreachable
    meta l4proto udp counter name blocked_udp reject with icmpx port-unreachable
  }
}
NFT
}

if nft_redirect 2>"$STATE_DIR/nft.err"; then
  # No IPv6 in a default Docker bridge network, so a v6 failure is normal
  # and not worth failing the run over: the v4 hook is the gate.
  nft_redirect6 2>>"$STATE_DIR/nft.err" || \
    echo "egress-guard: no IPv6 nat hook (expected without IPv6)" >&2
  echo redirect > "$STATE_DIR/mode"
else
  echo "egress-guard: nat hook unavailable, degrading to reject+counters" >&2
  sed 's/^/egress-guard: /' "$STATE_DIR/nft.err" >&2 || true
  nft_reject
  echo reject > "$STATE_DIR/mode"
fi

echo "egress-guard: armed in $(cat "$STATE_DIR/mode") mode, log $STATE_DIR/egress.jsonl"
