#!/usr/bin/env bash
# The fetch gate (LICENSE-001) around a build's steps: every TCP connection
# the runner opens on port 80 or 443 is redirected to mitmproxy, running
# scripts/fetch_gate.py as its own user, which forwards only what
# scripts/fetch_allowlist.txt and components.tsv's url: rows name; any other
# connection off the runner is refused, so a tool that ignores proxy settings
# cannot go around it. INTEG-016's guard (egress_guard_arm.sh) forwards
# nothing, and a build has to fetch, hence a second ruleset.
#
#   scripts/fetch_gate.sh arm      as root, before the build's first fetch
#   scripts/fetch_gate.sh disarm   after it, always; fails on a refused fetch
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${WS_FETCH_STATE:-/tmp/ws-fetch}"
PORT="${WS_FETCH_PORT:-19533}"
GATE_USER=wsfetch
MITMPROXY_VERSION=12.2.3
CA=/usr/local/share/ca-certificates/ws-fetch-gate.crt
# An unlisted repository on a listed host: the gate must answer it itself.
PROBE=https://github.com/torvalds/linux

die() { echo "fetch-gate: $*" >&2; exit 1; }

arm() {
  [ "$(id -u)" = 0 ] || die "needs root to install the ruleset"
  command -v nft >/dev/null || die "nft not installed"
  mkdir -p "$STATE"
  if [ ! -x "$STATE/venv/bin/mitmdump" ]; then
    python3 -m venv "$STATE/venv"
    "$STATE/venv/bin/pip" install --quiet "mitmproxy==$MITMPROXY_VERSION"
  fi
  id -u "$GATE_USER" >/dev/null 2>&1 || useradd --system --no-create-home "$GATE_USER"
  mkdir -p "$STATE/conf"
  : > "$STATE/fetch.jsonl"
  chown -R "$GATE_USER" "$STATE/conf" "$STATE/fetch.jsonl"

  uid=$(id -u "$GATE_USER")
  # upstream_cert=false: a refused request never opens a connection off the runner.
  nohup setpriv --reuid="$uid" --regid="$(id -g "$GATE_USER")" --clear-groups \
    env WS_FETCH_LOG="$STATE/fetch.jsonl" \
    "$STATE/venv/bin/mitmdump" --mode transparent --listen-host 127.0.0.1 --listen-port "$PORT" \
    --set confdir="$STATE/conf" --set upstream_cert=false --set stream_large_bodies=1m \
    -q -s "$HERE/fetch_gate.py" > "$STATE/mitmdump.log" 2>&1 &
  echo $! > "$STATE/pid"
  for _ in $(seq 1 100); do
    [ -f "$STATE/conf/mitmproxy-ca-cert.pem" ] && break
    sleep 0.1
  done
  [ -f "$STATE/conf/mitmproxy-ca-cert.pem" ] || { cat "$STATE/mitmdump.log" >&2; die "mitmproxy did not come up"; }
  cp "$STATE/conf/mitmproxy-ca-cert.pem" "$CA"
  update-ca-certificates > /dev/null

  nft -f - <<NFT
table inet ws_fetch
delete table inet ws_fetch
table inet ws_fetch {
  chain nat_out {
    type nat hook output priority dstnat; policy accept;
    meta skuid $uid return
    ip daddr 127.0.0.0/8 return
    ip6 daddr ::1 return
    tcp dport { 80, 443 } redirect to :$PORT
  }
  chain filter_out {
    type filter hook output priority filter; policy accept;
    meta skuid $uid accept
    oif "lo" accept
    ip daddr 127.0.0.0/8 accept
    meta l4proto { tcp, udp } th dport 53 accept
    reject with icmpx port-unreachable
  }
}
NFT

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROBE" || true)
  [ "$code" = 403 ] || die "$PROBE answered $code, not the gate's 403: the gate is not in the way"
  if curl -s -o /dev/null --max-time 5 http://1.1.1.1:8080/; then
    die "a connection on another port left the runner"
  fi
  mv "$STATE/fetch.jsonl" "$STATE/probe.jsonl"
  : > "$STATE/fetch.jsonl"
  chown "$GATE_USER" "$STATE/fetch.jsonl"
  echo "fetch-gate: armed, log $STATE/fetch.jsonl"
}

disarm() {
  nft delete table inet ws_fetch 2>/dev/null || true
  [ -f "$STATE/pid" ] && kill "$(cat "$STATE/pid")" 2>/dev/null || true
  rm -f "$CA" "$STATE/pid"
  update-ca-certificates --fresh > /dev/null
  [ -f "$STATE/fetch.jsonl" ] || die "no log at $STATE/fetch.jsonl: the gate was never armed"
  python3 "$HERE/fetch_gate.py" report "$STATE/fetch.jsonl"
}

case "${1:-}" in
  arm) arm ;;
  disarm) disarm ;;
  *) die "usage: $0 arm|disarm" ;;
esac
