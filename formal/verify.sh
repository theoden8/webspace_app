#!/usr/bin/env bash
# From a code change to every formal check, in one command. Parts of the
# models are printed from the code, so nothing derived is committed and each
# run checks the code as it is now:
#
#   PRINT    test/formal_model/main.dart prints the modules the code
#            defines (FORMAL_OUT)
#   SCHEDULES flutter test explores schedules and writes their traces
#            (MODEL_STEPS_DIR)
#   LEAN     formal/lean/check.sh: the theorems on how a check may be
#            split, and the printed footprints' cone decision
#   MODELS   check.sh: every TLC model, activation.tla with the printed
#            modules, each printed mutant caught
#   STEPS    trace/check_steps.sh: every marked step against activation.tla
#   PROOFS   proofs/check_proofs.sh: TLAPS, with the printed modules
#   LEVELS   levels.py: no count of what was checked falls below
#            formal/levels.tsv
#
# usage: verify.sh [--fast | --resume | --stage prepare|schedules|models|steps|proofs|finish]
#   --fast   PRINT without the traces, LEAN, then check.sh's ACTIVATION
#            section: the step tables against the model and their mutants,
#            in about four minutes on four cores
#   --resume the whole run, keeping build/formal: the printed model and each
#            schedule shard are kept while input_key.py's key (the files, the
#            schedule and walk variables, the Flutter version) is the one they
#            were made under, and MODELS, STEPS and PROOFS take what their
#            memos hold. The memos live in FORMAL_CACHE and TLAPM_CACHE_DIR;
#            point both at a path that outlives the machine to resume there.
#
# --stage runs the same phase independently for CI; finish requires the
# complete prepared registry, all model shards, replay and proof summaries.
# Needs Flutter (FLUTTER, default `fvm flutter`), Java, Python 3 and, without
# --fast, tlapm on PATH; lake (elan) for LEAN, which skips without it unless
# CI=true. Writes under build/formal/.
set -euo pipefail

FAST=0
RESUME=0
STAGE=all
case "${1:-}" in
  --fast) FAST=1 ;;
  --resume) RESUME=1 ;;
  --stage) STAGE="${2:-}" ;;
  "") ;;
  *) echo "usage: $0 [--fast | --resume | --stage prepare|schedules|models|steps|proofs|finish]" >&2; exit 2 ;;
esac
case "$STAGE" in
  all|prepare|schedules|models|steps|proofs|finish) ;;
  *) echo "unknown formal stage: $STAGE" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/formal"
FLUTTER="${FLUTTER:-fvm flutter}"
need() { command -v "$1" >/dev/null 2>&1 || { echo "verify.sh needs $1 on PATH${2:+ ($2)}" >&2; exit 2; }; }
need java
need python3
if [ "$FAST" -eq 0 ] && { [ "$STAGE" = all ] || [ "$STAGE" = proofs ]; }; then
  need tlapm "see formal/proofs/check_proofs.sh"
fi
cd "$ROOT"
mkdir -p "$OUT"
KEY=""
if [ "$RESUME" -eq 1 ]; then
  KEY="$(python3 -I "$ROOT/formal/input_key.py" "$ROOT" --tool "$($FLUTTER --version --machine 2>&1)")"
fi

# kept <stamp> <what>: the stamp names this run's key, so the stage it marks
# is reused.
kept() { [ "$RESUME" -eq 1 ] && [ -f "$1" ] && [ "$(cat "$1")" = "$KEY${2:+ $2}" ]; }

prepare() {
  echo "══ PRINT: the modules the code defines ══"
  if kept "$OUT/model/.key"; then
    echo "  KEPT the printed model, made under this key"
    return 0
  fi
  rm -rf "$OUT/model"
  local status=0 jar="${TLA2TOOLS_JAR:-$ROOT/formal/tla2tools.jar}"
  case "$jar" in /*) ;; *) jar="$ROOT/formal/$jar" ;; esac
  FORMAL_OUT="$OUT/model" $FLUTTER test test/formal_model/main.dart || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 79 ] || return "$status"
  [ -f "$OUT/model/models.json" ] || { echo "test/formal_model/main.dart wrote nothing under $OUT/model" >&2; return 1; }
  FORMAL_MODEL="$OUT/model" TLA2TOOLS_JAR="$jar" "$ROOT/formal/check.sh" --jar
  if [ ! "$jar" -ef "$OUT/model/tla2tools.jar" ]; then
    cp "$jar" "$OUT/model/tla2tools.jar"
  fi
  FORMAL_MODEL="$OUT/model" FORMAL_MANIFEST="$OUT/model/checks_registry.tsv" \
    TLA2TOOLS_JAR="$OUT/model/tla2tools.jar" "$ROOT/formal/check.sh" --plan
  if [ "$RESUME" -eq 1 ]; then echo "$KEY" >"$OUT/model/.key"; fi
}

# reap_shard: waits for the next schedule shard to end; stamps it under
# --resume when it passed, and keeps the failure's status otherwise.
reap_shard() {
  local done="" rc=0
  wait -n -p done || rc=$?
  local i="${shard_of[$done]}"
  unset "shard_of[$done]"
  if [ "$rc" -ne 0 ]; then
    status=$rc
  elif [ "$RESUME" -eq 1 ]; then
    mkdir -p "$OUT/steps/$i"
    echo "$KEY $i/$shards" >"$OUT/steps/$i/.key"
  fi
}

schedules() {
  echo "══ SCHEDULES: explore interleavings and record their traces ══"
  [ "$RESUME" -eq 1 ] || rm -rf "$OUT/steps"
  # The schedules record their traces in FORMAL_SLOTS shards side by side,
  # each into its own directory. The largest sweeps split their scripts
  # across shards; other tests run every nth test (SCHEDULE_SHARD).
  # The replay merges a configuration's shards into one trie, so what it
  # replays and counts is the same however many ran.
  shards="${FORMAL_SLOTS:-$(getconf _NPROCESSORS_ONLN)}"
  # At most FORMAL_PARALLEL shards run at once (default: all of them). Under
  # --resume each shard is stamped as it ends, so more shards than run at
  # once lose at most the ones under way when a run is stopped.
  parallel="${FORMAL_PARALLEL:-$shards}"
  declare -A shard_of=()
  status=0
  # A shard of a run split another way would join the replay's merge.
  for dir in "$OUT"/steps/*/; do
    [ -d "$dir" ] || continue
    i="$(basename "$dir")"
    case "$i" in *[!0-9]*) rm -rf "$dir"; continue ;; esac
    [ "$i" -lt "$shards" ] || rm -rf "$dir"
  done
  for i in $(seq 0 $((shards - 1))); do
    if kept "$OUT/steps/$i/.key" "$i/$shards"; then
      printf '  KEPT schedule shard %s/%s, recorded under this key\n' "$((i + 1))" "$shards"
      continue
    fi
    while [ "${#shard_of[@]}" -ge "$parallel" ]; do reap_shard; done
    rm -rf "$OUT/steps/$i"
    printf '  START schedule shard %s/%s\n' "$((i + 1))" "$shards"
    # GitHub's default reporter has no timestamped loading line for the
    # startup handshake below, so it would serialize the entire shards.
    MODEL_STEPS_DIR="$OUT/steps/$i" SCHEDULE_SHARD="$i/$shards" \
      $FLUTTER test --reporter expanded test/activation_schedules_test.dart >"$OUT/steps.$i.log" 2>&1 &
    pid=$!
    shard_of[$pid]=$i
    # Each flutter test copies the test assets under build/ as it starts,
    # and two starting together race on the copy, so the next starts once
    # this one is loading its tests, or has ended.
    while kill -0 "$pid" 2>/dev/null &&
      ! grep -E '^[0-9]+:[0-9]+ [+]' "$OUT/steps.$i.log" >/dev/null; do
      sleep 1
    done
  done
  while [ "${#shard_of[@]}" -gt 0 ]; do reap_shard; done
  if [ "$status" -ne 0 ]; then
    cat "$OUT"/steps.*.log
    exit "$status"
  fi
}

lean() {
  echo "══ LEAN: how a check may be split (formal/lean/) ══"
  if command -v lake >/dev/null 2>&1; then
    "$ROOT/formal/lean/check.sh" "$OUT/model/lean/Footprints.lean"
  elif [ "${CI:-}" = true ]; then
    echo "verify.sh needs lake on PATH in CI (elan; formal/lean/lean-toolchain pins the version)" >&2
    exit 2
  else
    echo "  SKIP lake not on PATH: the Lean check did not run (formal/lean/check.sh)"
  fi
}

prepared_jar() {
  export TLA2TOOLS_JAR="$OUT/model/tla2tools.jar"
  [ -f "$TLA2TOOLS_JAR" ] || { echo "prepared model has no TLC jar; run --stage prepare first" >&2; return 2; }
}

models() {
  echo "══ MODELS: shard ${FORMAL_SHARD:-0/1} ══"
  prepared_jar
  local report="$OUT/model-shards/local"
  rm -rf "$report"
  mkdir -p "$report"
  FORMAL_MODEL="$OUT/model" FORMAL_MANIFEST="$report/manifest.tsv" \
    FORMAL_COVERAGE="$report/coverage" FORMAL_DEFER_GATES=1 \
    "$ROOT/formal/check.sh" | tee "$report/models.log"
}

steps() {
  prepared_jar
  echo "══ STEPS ══"
  "$ROOT/formal/trace/check_steps.sh" "$OUT/steps" "$OUT/model" | tee "$OUT/steps.log"
}

proofs() {
  echo "══ PROOFS ══"
  FORMAL_MODEL="$OUT/model" "$ROOT/formal/proofs/check_proofs.sh" | tee "$OUT/proofs.log"
}

finish() {
  prepared_jar
  python3 -I "$ROOT/formal/model_shards.py" "$OUT/model-shards" \
    --registry "$OUT/model/checks_registry.tsv" \
    --out "$OUT/models.log" --coverage "$OUT/model/coverage"
  FORMAL_MODEL="$OUT/model" "$ROOT/formal/check.sh" --gates | tee -a "$OUT/models.log"
  # The proof job's shards each kept their own report: every module proved
  # by exactly one of them, the tables' sum over all (proof_shards.py).
  if [ -d "$OUT/proof-shards" ]; then
    echo "══ PROOFS: every shard's report, each module once ══"
    cat "$OUT"/proof-shards/*/proofs.log >"$OUT/proofs.log"
    python3 -I "$ROOT/formal/proofs/proof_shards.py" merge --model "$OUT/model" \
      --proofs "$ROOT/formal/proofs" "$OUT"/proof-shards/*/proofs.log | tee -a "$OUT/proofs.log"
  fi
  echo "══ LEVELS: verification only grows (formal/levels.tsv) ══"
  logs=(--models "$OUT/models.log" --steps "$OUT/steps.log" --proofs "$OUT/proofs.log")
  python3 -I "$ROOT/formal/levels.py" "$ROOT/formal/levels.tsv" "${logs[@]}" --out "$OUT/levels.tsv"
  # Raise the measured counts: the committed floors may all have been exceeded.
  if python3 -I "$ROOT/formal/levels.py" "$OUT/levels.tsv" "${logs[@]}" \
      --out "$OUT/levels_planted.tsv" --plant >/dev/null 2>&1; then
    echo "FAIL: a floor raised by one passed, so the levels gate is vacuous" >&2; exit 1
  fi
  echo "  OK   planted: a floor above the run is caught"
  echo "Every formal check passed."
}

case "$STAGE" in
  prepare) rm -rf "$OUT"; mkdir -p "$OUT"; prepare; lean ;;
  schedules) schedules ;;
  models) models ;;
  steps) steps ;;
  proofs) proofs ;;
  finish) finish ;;
  all)
    if [ "$RESUME" -eq 0 ]; then rm -rf "$OUT"; fi
    mkdir -p "$OUT"
    prepare
    if [ "$FAST" -eq 0 ]; then schedules; fi
    lean
    if [ "$FAST" -eq 1 ]; then
      FORMAL_MODEL="$OUT/model" FORMAL_ONLY=ACTIVATION "$ROOT/formal/check.sh"
    else
      models
      steps
      proofs
      finish
    fi
    ;;
esac
