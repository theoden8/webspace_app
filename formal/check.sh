#!/usr/bin/env bash
# Run the formal verification kernel. Fetches tla2tools.jar if absent.
#   - kernel.cfg                  (good composition)        MUST pass
#   - kernel_conflict_repaint.cfg (liveness non-mix, BUG-001) MUST violate RepaintLiveness
#   - kernel_conflict_evict.cfg   (safety non-mix)          MUST violate Inv_CurrentLoaded
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

expect() { # <cfg> <grep-pattern> <human-label>
  local out; out="$(run "$1" || true)"
  if echo "$out" | grep -q "$2"; then
    echo "  OK: $3"
  else
    echo "$out" | tail -30
    echo "FAIL: $1 did not produce expected outcome ($3)" >&2
    exit 1
  fi
}

echo "── good composition (kernel.cfg): expect PASS ──"
expect kernel.cfg "No error has been found" "all properties hold"

echo "── liveness non-mix (kernel_conflict_repaint.cfg): expect RepaintLiveness VIOLATED ──"
expect kernel_conflict_repaint.cfg "Temporal properties were violated" \
  "bypass route correctly fails to mix (liveness counterexample)"

echo "── safety non-mix (kernel_conflict_evict.cfg): expect Inv_CurrentLoaded VIOLATED ──"
expect kernel_conflict_evict.cfg "Inv_CurrentLoaded is violated" \
  "evict-current correctly fails to mix (safety counterexample)"

echo "All formal checks behaved as expected."
