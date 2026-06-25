#!/usr/bin/env bash
# Run the formal verification kernel. Fetches tla2tools.jar if absent.
#   - kernel.cfg          (good composition)    MUST pass
#   - kernel_conflict.cfg (non-mix demonstrator) MUST violate RepaintLiveness
# Exit non-zero if either expectation is unmet. CI-wireable.
set -euo pipefail

cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  curl -fsSL -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

run() { java -cp "$JAR" tlc2.TLC -config "$1" kernel.tla 2>&1; }

echo "── good composition (kernel.cfg): expect PASS ──"
good="$(run kernel.cfg)"
if echo "$good" | grep -q "No error has been found"; then
  echo "  OK: all properties hold"
else
  echo "$good" | tail -30
  echo "FAIL: good composition did not pass" >&2
  exit 1
fi

echo "── non-mix demonstrator (kernel_conflict.cfg): expect RepaintLiveness VIOLATED ──"
bad="$(run kernel_conflict.cfg || true)"
if echo "$bad" | grep -q "Temporal properties were violated"; then
  echo "  OK: demonstrator correctly fails to mix (liveness counterexample produced)"
else
  echo "$bad" | tail -30
  echo "FAIL: demonstrator did not produce the expected liveness violation" >&2
  exit 1
fi

echo "All formal checks behaved as expected."
