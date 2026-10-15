#!/usr/bin/env bash
# From a code change to every formal check, in one command. Parts of the
# models are printed from the code, so nothing derived is committed and each
# run checks the code as it is now:
#
#   PRINT    lib/formal_model/main.dart prints the modules the code
#            defines (FORMAL_OUT), and flutter test writes the traces the
#            schedules ran (MODEL_STEPS_DIR)
#   LEAN     formal/lean/check.sh: the theorems on how a check may be
#            split, and the printed footprints' cone decision
#   MODELS   check.sh: every TLC model, activation.tla with the printed
#            modules, each printed mutant caught
#   STEPS    trace/check_steps.sh: every marked step against activation.tla
#   PROOFS   proofs/check_proofs.sh: TLAPS, with the printed modules
#   LEVELS   levels.py: no count of what was checked falls below
#            formal/levels.tsv
#
# usage: verify.sh [--fast]
#   --fast   PRINT without the traces, LEAN, then check.sh's ACTIVATION
#            section: the step tables against the model and their mutants,
#            in about four minutes on four cores
#
# Needs Flutter (FLUTTER, default `fvm flutter`), Java, Python 3 and, without
# --fast, tlapm on PATH; lake (elan) for LEAN, which skips without it unless
# CI=true. Writes under build/formal/.
set -euo pipefail

FAST=0
case "${1:-}" in
  --fast) FAST=1 ;;
  "") ;;
  *) echo "usage: $0 [--fast]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/formal"
FLUTTER="${FLUTTER:-fvm flutter}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "verify.sh needs $1 on PATH${2:+ ($2)}" >&2; exit 2; }; }
need java
need python3
[ "$FAST" -eq 1 ] || need tlapm "see formal/proofs/check_proofs.sh"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "══ PRINT: the modules the code defines$([ "$FAST" -eq 1 ] || echo ", and the traces") ══"
cd "$ROOT"
# A main, not a test: the runner exits 79 when it finds no tests to run.
status=0
FORMAL_OUT="$OUT/model" $FLUTTER test lib/formal_model/main.dart || status=$?
[ "$status" -eq 0 ] || [ "$status" -eq 79 ] || exit "$status"
[ -f "$OUT/model/models.json" ] || { echo "lib/formal_model/main.dart wrote nothing under $OUT/model" >&2; exit 1; }
if [ "$FAST" -eq 0 ]; then
  # The schedules record their traces in FORMAL_SLOTS shards side by side,
  # each into its own directory, each every nth test (SCHEDULE_SHARD: the
  # heavy worlds are declared together, so a contiguous cut leaves one
  # shard with most of the work); the replay merges a configuration's
  # shards into one trie, so what it replays and counts is the same however
  # many ran.
  shards="${FORMAL_SLOTS:-$(getconf _NPROCESSORS_ONLN)}"
  pids=""
  for i in $(seq 0 $((shards - 1))); do
    MODEL_STEPS_DIR="$OUT/steps/$i" SCHEDULE_SHARD="$i/$shards" \
      $FLUTTER test test/activation_schedules_test.dart >"$OUT/steps.$i.log" 2>&1 &
    pids="$pids $!"
  done
  status=0
  for pid in $pids; do wait "$pid" || status=$?; done
  if [ "$status" -ne 0 ]; then
    cat "$OUT"/steps.*.log
    exit "$status"
  fi
fi

echo "══ LEAN: how a check may be split (formal/lean/) ══"
if command -v lake >/dev/null 2>&1; then
  "$ROOT/formal/lean/check.sh" "$OUT/model/lean/Footprints.lean"
elif [ "${CI:-}" = true ]; then
  echo "verify.sh needs lake on PATH in CI (elan; formal/lean/lean-toolchain pins the version)" >&2
  exit 2
else
  echo "  SKIP lake not on PATH: the Lean check did not run (formal/lean/check.sh)"
fi

if [ "$FAST" -eq 1 ]; then
  echo "══ MODELS: activation.tla with the printed modules ══"
  FORMAL_MODEL="$OUT/model" FORMAL_ONLY=ACTIVATION "$ROOT/formal/check.sh"
  exit 0
fi

echo "══ MODELS ══"
FORMAL_MODEL="$OUT/model" "$ROOT/formal/check.sh" | tee "$OUT/models.log"
echo "══ STEPS ══"
"$ROOT/formal/trace/check_steps.sh" "$OUT/steps" "$OUT/model" | tee "$OUT/steps.log"
echo "══ PROOFS ══"
FORMAL_MODEL="$OUT/model" "$ROOT/formal/proofs/check_proofs.sh" | tee "$OUT/proofs.log"
echo "══ LEVELS: verification only grows (formal/levels.tsv) ══"
logs=(--models "$OUT/models.log" --steps "$OUT/steps.log" --proofs "$OUT/proofs.log")
python3 -I "$ROOT/formal/levels.py" "$ROOT/formal/levels.tsv" "${logs[@]}" --out "$OUT/levels.tsv"
if python3 -I "$ROOT/formal/levels.py" "$ROOT/formal/levels.tsv" "${logs[@]}" \
    --out "$OUT/levels_planted.tsv" --plant >/dev/null 2>&1; then
  echo "FAIL: a floor raised by one passed, so the levels gate is vacuous" >&2; exit 1
fi
echo "  OK   planted: a floor above the run is caught"
echo "Every formal check passed."
