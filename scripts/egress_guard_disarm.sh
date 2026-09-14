#!/usr/bin/env bash
# Tear down the CI egress guard and snapshot what it saw (INTEG-016).
#
# Always run this, including on a failed test step -- an armed guard takes
# the network away from every later step in the job (artifact upload, the
# next build). Safe to run when nothing was armed.
set -uo pipefail

STATE_DIR="${WS_EGRESS_STATE:-/tmp/ws-egress}"

nft delete table ip ws_egress 2>/dev/null || true
nft delete table ip6 ws_egress 2>/dev/null || true
# Counters have to be read before the table goes, so the reject ruleset is
# dumped first and only then deleted.
if nft list table inet ws_egress_filter > "$STATE_DIR/counters.txt" 2>/dev/null; then
  nft delete table inet ws_egress_filter 2>/dev/null || true
fi

if [ -f "$STATE_DIR/recorder.pid" ]; then
  PID="$(cat "$STATE_DIR/recorder.pid")"
  # SIGTERM, not SIGKILL: the recorder writes its repeat-count summary on
  # the way out.
  kill -TERM "$PID" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$PID" 2>/dev/null || true
  rm -f "$STATE_DIR/recorder.pid"
fi

if [ -f "$STATE_DIR/resolv.conf.orig" ]; then
  cat "$STATE_DIR/resolv.conf.orig" > /etc/resolv.conf
fi

echo "egress-guard: disarmed"
