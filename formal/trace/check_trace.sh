#!/usr/bin/env bash
# Trace conformance: parse LogService fixtures into TLC modules and validate
# them against the kernel's observable projection (conformance.tla).
#   - sample_good.tracelog  -> MUST conform   (a real navigation trace)
#   - sample_bad.tracelog   -> MUST be caught (activates a site that isn't loaded)
# Generated mc_*.tla / mc_*.cfg are derivatives (regenerated here, gitignored).
set -euo pipefail

cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-../tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  curl -fsSL -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

PY="${PYTHON:-python3}"

# run <name> -> stdout of TLC (|| true so a violation's nonzero exit is data,
# not a pipeline failure under set -e/pipefail).
run() { java -cp "$JAR" tlc2.TLC -config "mc_$1.cfg" "mc_$1.tla" 2>&1 || true; }

echo "── GOOD trace (sample_good.tracelog): expect CONFORMS ──"
"$PY" parse_log.py sample_good.tracelog good
good_out="$(run good)"
if echo "$good_out" | grep -q "No error has been found"; then
  echo "  OK: trace conforms to the kernel's observable projection"
else
  echo "$good_out" | tail -25; echo "FAIL: good trace did not conform" >&2; exit 1
fi

echo "── BAD trace (sample_bad.tracelog): expect CAUGHT ──"
"$PY" parse_log.py sample_bad.tracelog bad
bad_out="$(run bad)"
# TLC says "X is violated" for reachable states and "invariant of X is equal to
# FALSE" when it fails in the initial state (our trace is a single state).
if echo "$bad_out" | grep -qE "(Conforms|ObsOK) is (violated|equal to FALSE)"; then
  echo "  OK: conformance correctly rejected the illegal trace"
else
  echo "$bad_out" | tail -25; echo "FAIL: bad trace was not caught" >&2; exit 1
fi

echo "Trace conformance behaved as expected."
