#!/usr/bin/env bash
# Model <-> code in both directions, for every Dart walk that wrote a trace
# (test/helpers/walk/model_trace.dart, under MODEL_WALK_DIR):
#
#   <trace-dir>  -> MUST hold: every step is a path the model allows, and
#                   every transition is taken or listed in walk_uncovered.tsv
#   walk_bad/    -> MUST be caught: a step into a state the model cannot reach
#                   (the jar holding another site's cookies) and memory
#                   pressure switching the site on screen (anti-vacuity)
#
# usage: check_walk.sh <trace-dir>
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <trace-dir>" >&2; exit 2; }
TRACES="$(cd "$1" && pwd)"
cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-../tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  # Same source and retries as formal/check.sh, unpinned for the same reason.
  curl -fsSL --retry 4 --retry-delay 2 -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi
PY="${PYTHON:-python3}"

echo "── WALKS: the code's steps against the models' state graphs ──"
"$PY" -I check_walk.py "$TRACES" --jar "$JAR"

echo "── WALK_BAD: a step outside the model MUST be caught ──"
if bad="$("$PY" -I check_walk.py walk_bad --jar "$JAR" 2>&1)"; then
  echo "$bad"; echo "FAIL: walk_bad/ passed, so the check is vacuous" >&2; exit 1
fi
for expected in "which the model cannot" "no path matching 'Evict?'"; do
  if ! grep -qF "$expected" <<<"$bad"; then
    echo "$bad"; echo "FAIL: walk_bad/ was not caught for: $expected" >&2; exit 1
  fi
done
echo "  OK   walk_bad/ caught: an unreachable state and an illegal path"
