#!/usr/bin/env bash
# Perf budget: run the native-free host benchmarks on this tree and on the base
# ref (a worktree off the same clone, so the pub cache is shared), and compare
# their medians as a ratio (tool/perf/perf_budget.dart against
# test/perf/budgets.tsv). Both runs share this machine and Flutter version, so
# the ratio cancels the host out.
#
#   scripts/perf_budget.sh [base-ref]        # default origin/master
#
# Report-only by default: it prints the table and exits 0 even when a benchmark
# run fails (a transient pub-get network blip is not a perf signal), so it never
# blocks a PR. With WS_PERF_BUDGET_ENFORCE=1 a failed run or a measurement past
# its ceiling exits nonzero. Every run's full output is kept under the output
# dir for the CI artifact, so a failure is diagnosable without the gate failing.
set -uo pipefail

base_ref="${1:-origin/master}"
export WS_PERF=1
export WS_PERF_RUNS="${WS_PERF_RUNS:-15}"
enforce="${WS_PERF_BUDGET_ENFORCE:-0}"

flutter="${WS_FLUTTER:-fvm flutter}"
dart="${WS_DART:-fvm dart}"

root="$(cd "$(dirname "$0")/.." && pwd)"
benchmarks=(
  test/perf/url_change_bench_test.dart
  test/perf/startup_modes_bench_test.dart
)

out_dir="${WS_PERF_BUDGET_DIR:-$(mktemp -d)}"
mkdir -p "$out_dir"
# Absolute: a benchmark run cds into the base worktree, and WS_PERF_OUT and the
# per-run logs must resolve to this dir, not to one under the worktree's cwd.
out_dir="$(cd "$out_dir" && pwd)"
head_out="$out_dir/head.jsonl"
base_out="$out_dir/base.jsonl"
: > "$head_out" # WS_PERF_OUT appends, so start each file empty
: > "$base_out"

# Run the benchmarks in $1, samples to $2, all output to $3 (kept as an
# artifact). One retry: pub get resolves a git dependency, and a transient
# network failure there is not a perf signal.
run_in_tree() {
  local tree="$1" out="$2" log="$3" attempt rc
  for attempt in 1 2; do
    rc=0
    (
      cd "$tree"
      $flutter pub get
      $dart tool/gen_l10n.dart
      WS_PERF_OUT="$out" $flutter test "${benchmarks[@]}"
    ) >"$log" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    echo "perf budget: run in $tree failed (attempt $attempt, exit $rc)"
    : > "$out" # a partial run left half a file; start the retry clean
  done
  echo "--- last 30 lines of $(basename "$log") ---"
  tail -30 "$log"
  return 1
}

work="$(mktemp -d)"
cleanup() { git -C "$root" worktree remove --force "$work" >/dev/null 2>&1 || true; }
trap cleanup EXIT

runs_ok=1
echo "perf budget: benchmarks on HEAD"
run_in_tree "$root" "$head_out" "$out_dir/head.log" || runs_ok=0

echo "perf budget: benchmarks on $base_ref"
if git -C "$root" worktree add --quiet --detach "$work" "$base_ref"; then
  run_in_tree "$work" "$base_out" "$out_dir/base.log" || runs_ok=0
else
  echo "perf budget: could not add a worktree at $base_ref"
  runs_ok=0
fi

breach=0
if [ -s "$head_out" ] && [ -s "$base_out" ]; then
  echo "perf budget: comparing head to $base_ref"
  WS_PERF_BUDGET_ENFORCE="$enforce" \
    $dart "$root/tool/perf/perf_budget.dart" "$base_out" "$head_out" \
    "$root/test/perf/budgets.tsv" | tee "$out_dir/report.txt"
  breach="${PIPESTATUS[0]}"
else
  echo "perf budget: not enough samples to compare (a benchmark run failed above)"
fi

# Report-only unless enforcing. When enforcing, a run that could not produce a
# baseline, or a measurement past its ceiling (the tool's own nonzero), fails.
if [ "$enforce" = '1' ] && [ "$runs_ok" -ne 1 ]; then
  echo "perf budget: a benchmark run failed; cannot gate without a baseline"
  exit 1
fi
exit "$breach"
