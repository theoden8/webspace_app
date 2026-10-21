#!/usr/bin/env bash
# Model <-> code, step for step, for every schedule the Dart enumeration ran
# (test/helpers/walk/step_traces.dart, under MODEL_STEPS_DIR), against
# formal/activation.tla with the modules lib/formal_model/main.dart
# printed from the code into <model-dir> (FORMAL_OUT):
#
#   <trace-dir>  -> MUST hold: every step the code marked is a step of
#                   the model ending in the state the code was in, and
#                   every branch is taken or listed in steps_uncovered.tsv
#   --plant      -> MUST be caught: a copy of a trace whose first nuke leaves
#                   the jar full, a step the model cannot take (anti-vacuity);
#                   it reads the kept replays, so a key that does not read the
#                   trace remembers it and fails here
#   --plant-key  -> MUST be caught: a replay whose key does not read the
#                   printed model, which TLC parsed
#
# usage: check_steps.sh <trace-dir> <model-dir>
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <trace-dir> <model-dir>" >&2; exit 2; }
TRACES="$(cd "$1" && pwd)"
MODEL="$(cd "$2" && pwd)"
cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-../tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  # Same source and retries as formal/check.sh, unpinned for the same reason.
  curl -fsSL --retry 4 --retry-delay 2 -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi
PY="${PYTHON:-python3}"

echo "── STEPS: each step the code marked, replayed against activation.tla ──"
"$PY" -I check_steps.py "$TRACES" --model "$MODEL" --jar "$JAR"

echo "── PLANTED: a step outside the model MUST be caught ──"
if bad="$("$PY" -I check_steps.py "$TRACES" --plant --model "$MODEL" --jar "$JAR" 2>&1)"; then
  echo "$bad"; echo "FAIL: the planted nuke passed, so the replay is vacuous" >&2; exit 1
fi
if ! grep -qF "the model cannot take a step the code took" <<<"$bad"; then
  echo "$bad"; echo "FAIL: the planted nuke was not caught by the replay" >&2; exit 1
fi
echo "  OK   planted: a nuke that leaves the jar full is caught"

if bad="$("$PY" -I check_steps.py "$TRACES" --plant-key --model "$MODEL" --jar "$JAR" 2>&1)"; then
  echo "$bad"; echo "FAIL: a key that does not read the model passed, so a remembered replay could be stale" >&2; exit 1
fi
if ! grep -qF "the replay's key did not read what TLC parsed" <<<"$bad"; then
  echo "$bad"; echo "FAIL: the key that does not read the model was not caught by the replay" >&2; exit 1
fi
echo "  OK   planted: a remembered replay's key that leaves out the model is caught"
