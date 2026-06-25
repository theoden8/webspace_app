#!/usr/bin/env bash
# Per-requirement test matrix for the verification kernel. Fetches tla2tools.jar
# if absent, then runs three classes of check:
#
#   GOOD      kernel.cfg                  -> all properties hold
#   NEGATIVE  *_conflict_*.cfg            -> a mutation MUST be caught (anti-vacuity:
#                                            proves the invariant actually constrains)
#   POSITIVE  *_reach_*.cfg               -> a reachability witness MUST be violated
#                                            (anti-inertness: proves the legal behavior
#                                            the green checks rely on is reachable)
#
# Exit non-zero if any expectation is unmet. CI-wireable.
set -euo pipefail

cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  curl -fsSL -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

run() { java -cp "$JAR" tlc2.TLC -config "$1" kernel.tla 2>&1; }

# expect <cfg> <grep-pattern> <human-label>
expect() {
  local out; out="$(run "$1" || true)"
  if echo "$out" | grep -q "$2"; then
    printf '  OK   %-34s %s\n' "$1" "$3"
  else
    echo "$out" | tail -30
    echo "FAIL: $1 did not produce expected outcome ($3)" >&2
    exit 1
  fi
}

echo "── GOOD: full composition holds ──"
expect kernel.cfg "No error has been found" "all properties hold"

echo "── NEGATIVE: each mutation is caught ──"
expect kernel_conflict_repaint.cfg "Temporal properties were violated" \
  "bypass route → RepaintLiveness violated (liveness non-mix)"
expect kernel_conflict_evict.cfg "Inv_CurrentLoaded is violated" \
  "evict-current → Inv_CurrentLoaded violated (safety non-mix)"
expect kernel_conflict_contaminate.cfg "Inv_JarMatchesVisible is violated" \
  "contaminate → Inv_JarMatchesVisible violated (cookie-leak non-mix)"

echo "── POSITIVE: each legal behavior is reachable (witness violated) ──"
expect kernel_reach_surface_attach.cfg "Reach_SurfaceAttach is violated" \
  "a blank surface attach is reachable (RepaintLiveness not vacuous)"
expect kernel_reach_site_switch.cfg "Reach_SiteSwitch is violated" \
  "activating a non-initial site is reachable"
expect kernel_reach_evict_bg.cfg "Reach_EvictBackground is violated" \
  "evicting a backgrounded site is reachable"

echo "── TRACE CONFORMANCE: code stayed inside the model ──"
case "$JAR" in /*) JAR_ABS="$JAR" ;; *) JAR_ABS="$(pwd)/$JAR" ;; esac
TLA2TOOLS_JAR="$JAR_ABS" ./trace/check_trace.sh | sed 's/^/  /'

echo "All formal checks behaved as expected."
