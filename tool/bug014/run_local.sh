#!/usr/bin/env bash
# Run the BUG-014 proxy arms on a real Mac, in slot order, and print the
# verdicts.
#
# The macOS CI tier exists because CI was the only place these ever ran, and
# it costs ~35 minutes to produce roughly one usable reading: gap -2 has one
# app process at a time able to proxy, so every arm behind the first measures
# a spent process. On real hardware that constraint may not exist at all,
# which is the first thing this script is for.
#
#   ./tool/bug014/run_local.sh --slot-check 3
#       Runs the timing arm three times. If `baseline=own` every time, the
#       slot is an artifact of GitHub's runners and every other arm becomes
#       cheap to run. If only the first reads `own`, the slot is real and is
#       macOS rather than the runner, which is a finding in itself.
#
#   ./tool/bug014/run_local.sh --ladder
#       The frame ladder: where the proxy boundary sits on the near side.
#       `frame1` is the control; the other rungs mean nothing without it.
#
#   ./tool/bug014/run_local.sh --all
#       Ladder, then timing, then the reassign pair. Slot order, so the arm
#       that needs the slot most asks first.
#
# Nothing here asserts. Every arm reports, because an arm without a live
# proxy control in its own process is not evidence, and the controls are what
# separate "the platform dropped the proxy" from "this process never had one".

set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This is an Apple-path investigation; the arms skip themselves elsewhere." >&2
  exit 1
fi

if ! command -v fvm >/dev/null 2>&1; then
  echo "fvm is not on PATH. Install it, then re-run:" >&2
  echo '  curl -fsSL https://fvm.app/install.sh | bash && export PATH="$HOME/fvm/bin:$PATH"' >&2
  exit 1
fi

# Apple never proxies a loopback destination, so an arm with no routable
# address to bind its origins on reads DIRECT for a reason that has nothing
# to do with this bug. Fail loudly rather than produce that.
if ! ifconfig 2>/dev/null | grep -qE 'inet (192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.'; then
  echo "warning: no non-loopback IPv4 found. Every arm will read DIRECT and" >&2
  echo "         none of it will be about BUG-014. Connect to a network first." >&2
fi

OUT="${TMPDIR:-/tmp}/bug014-local"
mkdir -p "$OUT"

# One at a time, and reaped in between: an app process that outlives its arm
# is a candidate for what the next arm's proxy is waiting on (gap -2).
reap() {
  if pgrep -x Webspace >/dev/null 2>&1; then
    echo "  (reaping a stale Webspace process)"
    pkill -x Webspace 2>/dev/null || true
    sleep 2
    pkill -9 -x Webspace 2>/dev/null || true
  fi
}

run_arm() {
  local target="$1" label="$2"
  shift 2
  local log="$OUT/$label.log"
  reap
  echo "=== $label ==="
  env "$@" fvm flutter test "$target" -d macos 2>&1 | tee "$log" >/dev/null || true
  grep -hE '\[proxy-(ladder|timing|reassign)\].*(verdict|baseline=)' "$log" \
    || echo "  no verdict line; see $log"
}

mode="${1:---all}"
case "$mode" in
  --slot-check)
    n="${2:-3}"
    echo "gap -2: does every process here get the proxy slot? ($n runs)"
    for i in $(seq 1 "$n"); do
      run_arm integration_test/proxy_timing_test.dart "timing-$i" \
        "WEBSPACE_TIMING_RUN=$i"
    done
    echo
    echo "Read 'baseline=': own on every run means the slot is a CI artifact."
    ;;
  --ladder)
    run_arm integration_test/proxy_frame_ladder_test.dart "ladder" \
      WEBSPACE_LADDER_RUN=local
    echo
    echo "Read 'frame1=': without own there, no other rung is evidence."
    ;;
  --all)
    run_arm integration_test/proxy_frame_ladder_test.dart "ladder" \
      WEBSPACE_LADDER_RUN=local
    run_arm integration_test/proxy_timing_test.dart "timing" \
      WEBSPACE_TIMING_RUN=local
    for kind in connect socks5; do
      reap
      echo "=== reassign-$kind ==="
      fvm flutter test integration_test/proxy_reassign_test.dart \
        --dart-define=WEBSPACE_REASSIGN=true \
        --dart-define=WEBSPACE_REASSIGN_KIND="$kind" \
        -d macos 2>&1 | tee "$OUT/reassign-$kind.log" >/dev/null || true
      grep -hE '\[proxy-reassign\].*verdict' "$OUT/reassign-$kind.log" \
        || echo "  no verdict line; see $OUT/reassign-$kind.log"
    done
    ;;
  *)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac

echo
echo "logs: $OUT"
