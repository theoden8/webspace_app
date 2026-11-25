#!/usr/bin/env bash
# Verification suite. Fetches tla2tools.jar if absent, then runs:
#
#   GOOD      kernel.cfg                  -> all properties hold
#   NEGATIVE  *_conflict_*.cfg            -> a mutation MUST be caught (anti-vacuity:
#                                            proves the invariant actually constrains)
#   POSITIVE  *_reach_*.cfg               -> a reachability witness MUST be violated
#                                            (anti-inertness: proves the legal behavior
#                                            the green checks rely on is reachable)
#   ARCHIVE   archive*.cfg                -> ARCH-001 byte-identity (self-composition)
#   ARCHIVE_TRANSFER archive_transfer*.cfg -> encrypted-slot handoff and recovery
#   ACTIVATION activation*.cfg            -> activation.tla, with the modules the
#                                            code prints (FORMAL_MODEL); each
#                                            printed mutant MUST be caught
#   TOAST     toast_page_boundary*.cfg     -> visible/queued ownership and
#                                            delayed-offer guards
#   ACTIVATION_TOAST activation_toast*.cfg -> the same rules composed with
#                                            activation.tla's real steps
#   TRACE     trace/check_trace.sh        -> code stayed inside the model (LogService)
#
# Exit non-zero if any expectation is unmet. formal/verify.sh prints the
# modules and runs this; on its own it needs FORMAL_MODEL, the directory
# test/formal_model/main.dart wrote (FORMAL_OUT). FORMAL_ONLY=<SECTION>
# runs one section (verify.sh --fast runs ACTIVATION).
#
# The list below is walked twice. The first walk only collects the TLC runs
# it names; a pool runs them in the background, FORMAL_SLOTS cores at a time
# (default: all of them), and the second walk reports each in the list's
# order once it has ended, so the output is what running them one after
# another printed. A run that did not behave prints TLC's error and the walk
# goes on, so every run that did is remembered, and the suite fails at the
# end, naming each that did not. Each run's time is
# kept under FORMAL_CACHE (default ~/.cache/webspace-formal) to size the
# next: the longest start first, with the most workers.
# FORMAL_RUN_BUDGET=<seconds> gives a run at least the workers its last time
# needs to end within that much wall time, for a machine that stops a
# command after a while: there a world the share leaves on one core never
# ends, and starts again from nothing.
# FORMAL_DEADLINE=<seconds> starts no run whose last time, on the workers it
# gets, would end it later than that many seconds after the suite began:
# such a run is deferred, the suite exits 3 naming each, and the next suite
# remembers every run this one finished. A run with no time yet always
# starts.
#
# A run whose inputs are byte for byte those of one that behaved before
# (for activation.tla, what of them its world can reach: world_key.py) is
# remembered there instead of run: it reports from the kept output, marked
# "(remembered)", and counts as the check it is (formal/README.md,
# "Remembered runs"). FORMAL_RERUN=1 runs every one.
#
# FORMAL_CHECKPOINT_MINUTES=<minutes> has TLC checkpoint a run that often,
# under FORMAL_CACHE in a directory named for the run's inputs, and a run that
# finds a checkpoint there recovers from it: a machine that restarts mid-suite
# loses at most that much of each run. 0, the default, keeps none, since a
# checkpoint copies the state queue beside the run's own.
set -euo pipefail

cd "$(dirname "$0")"

MODEL="${FORMAL_MODEL:-}"
if [ -z "$MODEL" ] || [ ! -f "$MODEL/activation_tables.tla" ]; then
  echo "FORMAL_MODEL names no printed modules; run formal/verify.sh" >&2
  exit 2
fi
MODEL="$(cd "$MODEL" && pwd)"

MODE="${1:-}"
[ -z "$MODE" ] || { [ "$MODE" = --gates ] || [ "$MODE" = --jar ] || [ "$MODE" = --plan ]; } || { echo "usage: check.sh [--gates|--jar|--plan]" >&2; exit 2; }
JAR="${TLA2TOOLS_JAR:-tla2tools.jar}"
"$(dirname "$0")/fetch_tla2tools.sh" "$JAR"

[ "$MODE" != --jar ] || exit 0

SHARD="${FORMAL_SHARD:-0/1}"
[[ "$SHARD" =~ ^([0-9]+)/([1-9][0-9]*)$ ]] || { echo "invalid FORMAL_SHARD: $SHARD" >&2; exit 2; }
SHARD_AT=$((10#${BASH_REMATCH[1]})) SHARD_COUNT=$((10#${BASH_REMATCH[2]}))
[ "$SHARD_AT" -lt "$SHARD_COUNT" ] || { echo "invalid FORMAL_SHARD: $SHARD" >&2; exit 2; }
COVERAGE_DIR="${FORMAL_COVERAGE:-$MODEL/coverage}"
SLOTS="${FORMAL_SLOTS:-$(getconf _NPROCESSORS_ONLN)}"
[ "$SLOTS" -ge 1 ] 2>/dev/null || { echo "FORMAL_SLOTS is not a count of cores: $SLOTS" >&2; exit 2; }
BUDGET="${FORMAL_RUN_BUDGET:-0}"
[ "$BUDGET" -ge 0 ] 2>/dev/null || { echo "FORMAL_RUN_BUDGET is not a count of seconds: $BUDGET" >&2; exit 2; }
DEADLINE="${FORMAL_DEADLINE:-0}"
[ "$DEADLINE" -ge 0 ] 2>/dev/null || { echo "FORMAL_DEADLINE is not a count of seconds: $DEADLINE" >&2; exit 2; }
PROGRESS="${FORMAL_PROGRESS_SECONDS:-60}"
CHECKPOINT="${FORMAL_CHECKPOINT_MINUTES:-0}"
[ "$CHECKPOINT" -ge 0 ] 2>/dev/null || { echo "FORMAL_CHECKPOINT_MINUTES is not a count of minutes: $CHECKPOINT" >&2; exit 2; }
[ "$PROGRESS" -ge 1 ] 2>/dev/null || { echo "FORMAL_PROGRESS_SECONDS is not a positive interval: $PROGRESS" >&2; exit 2; }
CACHE="${FORMAL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/webspace-formal}"
TIMES="$CACHE/times" MEMO="$CACHE/memo" CHECKPOINTS="$CACHE/checkpoints"
mkdir -p "$TIMES" "$MEMO" "$CHECKPOINTS"
# A world with no time of its own takes its recorded one (tlc_times.tsv), so
# a cold cache still plans the longest first and FORMAL_DEADLINE still holds.
while IFS=$'\t' read -r name secs; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -f "$TIMES/$name" ] || printf '%s 1\n' "$secs" >"$TIMES/$name"
done <tlc_times.tsv
# A kept run no check has asked for in a fortnight is dropped.
find "$MEMO" -type f -mtime +14 -delete
# Everything a run writes, under states/ (beside the repo's files, not in a
# tmpfs: a state queue is gigabytes for the base config), gone as this ends.
mkdir -p states
# owner: this machine's boot and this shell, which a run directory records so
# a later suite can tell one a restart left behind from one still in use.
owner() { echo "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo -) $1"; }
for left in states/run.*/; do
  [ -f "$left/owner" ] || continue
  read -r boot pid <"$left/owner" || continue
  [ "$(owner "$pid")" = "$boot $pid" ] && kill -0 "$pid" 2>/dev/null || rm -rf "$left"
done
RUNS="$(cd "$(mktemp -d states/run.XXXXXX)" && pwd)"
owner $$ >"$RUNS/owner"
mkdir "$RUNS/facts"
: >"$RUNS/jobs"
POOL=""
MANIFEST="${FORMAL_MANIFEST:-$RUNS/manifest.tsv}"
mkdir -p "$(dirname "$MANIFEST")"
printf 'SHARD\t%s\t%s\n' "$SHARD_AT" "$SHARD_COUNT" >"$MANIFEST"
trap '[ -z "$POOL" ] || { kill "$POOL"; wait "$POOL"; } 2>/dev/null || true; rm -rf "$RUNS"' EXIT

if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum | cut -d' ' -f1; }
else sha() { shasum -a 256 | cut -d' ' -f1; }; fi
JAR_SHA="$(sha <"$JAR")"

# names <file>: the modules a module names after EXTENDS or INSTANCE.
names() {
  tr '\n\t' '  ' <"$1" | grep -oE '(EXTENDS|INSTANCE) +[A-Za-z0-9_]+( *, *[A-Za-z0-9_]+)*' |
    sed -E 's/^(EXTENDS|INSTANCE) +//; s/ *, */ /g' | tr '\n' ' ' || true
}

# reads <dirs> <module>: every file a run of the module can read, as
# "<directory's place>/<name>.tla <sha>", closed over names: each name in
# every directory TLC searches (the spec's, then the library's), so a file
# another shadows still counts. A name in none is a standard module, which
# the jar holds. A file's sha and names are read once a run, kept under
# its absolute path (a directory that does not exist holds nothing).
reads() {
  local dirs="" todo="$2" seen=" " name dir i facts sum more
  while IFS= read -r dir; do
    dirs="$dirs$(cd "$dir" 2>/dev/null && pwd || true)"$'\n'
  done <<<"${1//:/$'\n'}"
  while read -r name todo <<<"$todo" && [ -n "$name" ]; do
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    i=0
    while IFS= read -r dir; do
      if [ -n "$dir" ] && [ -f "$dir/$name.tla" ]; then
        facts="$RUNS/facts$dir/$name"
        if [ ! -f "$facts" ]; then
          mkdir -p "${facts%/*}"
          { sha <"$dir/$name.tla"; names "$dir/$name.tla"; echo; } >"$facts"
        fi
        { read -r sum; read -r more; } <"$facts"
        echo "$i/$name.tla $sum"
        todo="$todo $more"
      fi
      i=$((i + 1))
    done <<<"$dirs"
  done
}

# key <cfg> <spec> <library> <pattern> <coverage>: a hash of what the run's
# verdict is a function of: the jar, the config, the line it must print,
# whether it prints coverage, and every module it reads, or, for a run of
# activation.tla, what of them its world can reach (world_key.py, which
# wrote it under $RUNS/worlds). Paths, labels and workers are not among
# them.
key() {
  local world; world="$RUNS/worlds/$(basename "$1" .cfg)"
  {
    echo "jar $JAR_SHA"
    echo "cfg $(sha <"$1")"
    printf 'expect %s\n' "$4"
    echo "coverage $5"
    if [ -f "$world" ]; then
      echo "memo 2"
      cat "$world"
    else
      echo "memo 1"
      reads "$(dirname "$2")${3:+:$3}" "$(basename "$2" .tla)" | LC_ALL=C sort
    fi
  } | sha
}

# plan: the collected runs (name, cfg, spec, library, coverage; "-" for
# none) in the order they start, each with its workers after its name. A
# run gets the share of the cores its last time (seconds by workers) is of
# all of theirs, at least one and, beside others, one fewer than every
# core. The longest start first, one with no time yet as long as the
# mean of those with one. Without a time, split the cores between two runs:
# starting every cold run with one worker strands the longest on one core.
# Under FORMAL_RUN_BUDGET a run gets at least its time over the budget.
plan() {
  local name job secs w cost
  while IFS=$'\t' read -r name job; do
    cost=-1
    if read -r secs w 2>/dev/null <"$TIMES/$name"; then cost=$((secs * w)); fi
    printf '%s\t%s\t%s\n' "$cost" "$name" "$job"
  done <"$RUNS/jobs" | awk -F'\t' -v OFS='\t' -v slots="$SLOTS" -v budget="$BUDGET" '
    { cost[NR] = $1; if ($1 > 0) { total += $1; known++ } name[NR] = $2
      sub(/^[^\t]*\t[^\t]*\t/, ""); job[NR] = $0 }
    END {
      cap = (NR > 1 && slots > 1) ? slots - 1 : slots
      mean = known ? total / known : 0
      for (i = 1; i <= NR; i++) {
        w = cost[i] > 0 ? int((slots * cost[i] + total - 1) / total) : int(slots / 2)
        if (budget > 0 && cost[i] > 0 && w < int((cost[i] + budget - 1) / budget))
          w = int((cost[i] + budget - 1) / budget)
        if (NR == 1) w = slots
        if (w < 1) w = 1
        if (w > cap) w = cap
        print (cost[i] < 0 ? mean : cost[i]), i, name[i], w, job[i]
      }
    }' | sort -t$'\t' -k1,1gr -k2,2n | cut -f3-
}

# pool: runs the plan in the background. Each run has its own metadir,
# named for its cfg (each cfg runs once, so the name is unique), and its own
# java.io.tmpdir, where TLC unpacks the standard modules and deletes them as
# it ends, under any run beside it. Nothing reads a metadir once TLC ends:
# left behind, the runs fill the disk.
pool() {
  trap 'kill $(jobs -p) 2>/dev/null; wait; exit 1' TERM
  local free="$SLOTS" running="" name w cfg spec lib cover meta recover
  while IFS=$'\t' read -r -u 4 name w cfg spec lib cover; do
    while [ "$free" -lt "$w" ]; do reap; done
    if ! fits "$name" "$w"; then
      touch "$RUNS/$name.deferred" "$RUNS/$name.done"
      continue
    fi
    [ "$lib" != - ] || lib=""
    [ "$cover" != - ] || cover=""
    mkdir -p "$RUNS/$name.tmp"
    echo "$SECONDS $w" >"$RUNS/$name.started"
    meta="$(metadir "$name")"
    recover="$(checkpoint "$meta")"
    java "-Djava.io.tmpdir=$RUNS/$name.tmp" ${lib:+"-DTLA-Library=$lib"} -cp "$JAR" \
      tlc2.TLC -workers "$w" -checkpoint "$CHECKPOINT" ${cover:+-coverage 100000} \
      ${recover:+-recover "$recover"} -metadir "$meta" -config "$cfg" "$spec" >"$RUNS/$name.out" 2>&1 &
    running="$running $!:$name:$w:$SECONDS"
    free=$((free - w))
  done 4< <(plan)
  while [ -n "$running" ]; do reap; done
}

# metadir <name>: where run <name> keeps its states: beside this suite's
# other files, or, with checkpoints on, in a directory named for the run's
# inputs (its key), which a restart leaves for the next suite.
metadir() {
  if [ "$CHECKPOINT" -gt 0 ]; then echo "$CHECKPOINTS/$(cat "$RUNS/$1.key")"
  else echo "$RUNS/$1.states"; fi
}

# checkpoint <metadir>: the newest checkpoint TLC finished writing there
# (its queue and its variables), or nothing.
checkpoint() {
  local d last=""
  [ "$CHECKPOINT" -gt 0 ] || return 0
  for d in "$1"/*/; do
    [ -f "$d/queue.chkpt" ] && [ -f "$d/vars.chkpt" ] && last="${d%/}"
  done
  echo "$last"
}

# fits: whether run <name> on <w> workers, at its last time, ends before
# FORMAL_DEADLINE; any run does without one, and a run with no time yet.
fits() {
  local secs w0
  [ "$DEADLINE" -gt 0 ] || return 0
  read -r secs w0 2>/dev/null <"$TIMES/$1" || return 0
  [ $((SECONDS + (secs * w0 + $2 - 1) / $2)) -le "$DEADLINE" ]
}

# reap: marks done each run of the pool's that has ended, and keeps the time
# of one that behaved. A run that died (the disk full, a kill) or stopped at
# an unexpected violation ends early, and its time would hand the world too
# few workers next time.
reap() {
  sleep 0.2
  local alive still="" entry pid name w t0 tmp
  alive=" $(jobs -rp | tr '\n' ' ') "
  for entry in $running; do
    IFS=: read -r pid name w t0 <<<"$entry"
    case "$alive" in *" $pid "*) still="$still $entry"; continue ;; esac
    # A checkpoint is for a run a restart cut short; one that ended, or a
    # recovery that failed, leaves none for the next suite to trust.
    rm -rf "$(metadir "$name")" "$RUNS/$name.tmp"
    if remember "$name"; then
      tmp="$(mktemp "$TIMES/.$name.XXXXXX")"
      echo "$((SECONDS - t0)) $w" >"$tmp" && mv "$tmp" "$TIMES/$name"
    fi
    touch "$RUNS/$name.done"
    free=$((free + w))
  done
  running="$still"
}

# remember: keeps a run that behaved under its key as it ends, so a suite
# cut short keeps every run it finished, not only those it reported, which
# wait in the list's order behind the longest.
remember() {
  local name="$1" tmp
  grep -E "$(cat "$RUNS/$name.expect")" "$RUNS/$name.out" >/dev/null || return 1
  tmp="$(mktemp "$MEMO/.$name.XXXXXX")"
  cp "$RUNS/$name.out" "$tmp" && mv "$tmp" "$MEMO/$(cat "$RUNS/$name.key")"
}

PASS=collect
ONLY="${FORMAL_ONLY:-}"
SECTION=""
selected() { [ -z "$ONLY" ] || [ "$ONLY" = "$SECTION" ]; }
reporting() { [ "$PASS" = report ] && selected; }
# section <NAME> <what it checks>
section() {
  SECTION="$1"
  if reporting; then echo "── $1: $2 ──"; fi
}

# expect <cfg> <model.tla> <grep-pattern> <human-label> [<printed-modules>]
# What each passing config counts as, by what it expects: a model that holds,
# a planted mistake caught, or a witness reached. verify.sh holds the totals
# to formal/levels.tsv.
HOLDS=0 CAUGHT=0 REACHED=0 FAILED="" DEFERRED=""
# owned <name>: whether this shard runs the check. The worlds are split by
# their recorded times with the proofs' rule (proofs/proof_shards.py), from
# the one file every shard reads, so the shards compute the same split.
owned() { [ "$SHARD_COUNT" -eq 1 ] || grep -xF "$1" "$RUNS/mine" >/dev/null; }
expect() {
  selected || return 0
  local name kind ordinal="$ORDINAL"
  ORDINAL=$((ORDINAL + 1))
  name="$(basename "$1" .cfg)"
  case "$3" in
    "No error has been found") kind=holds ;;
    Reach_*) kind=reached ;;
    *) kind=caught ;;
  esac
  if [ "$PASS" = list ]; then echo "$name" >>"$RUNS/all"; return 0; fi
  if [ "$PASS" = collect ]; then
    printf 'CHECK\t%s\t%s\t%s\n' "$ordinal" "$name" "$kind" >>"$MANIFEST"
    [ "$MODE" != --plan ] || return 0
  fi
  owned "$name" || return 0
  if [ "$PASS" = collect ]; then
    local covered=-; [ -z "${COVERAGE:-}" ] || covered=on
    local k; k="$(key "$1" "$2" "${5:-}" "$3" "$covered")"
    echo "$k" >"$RUNS/$name.key"
    printf '%s\n' "$3" >"$RUNS/$name.expect"
    if [ -z "${FORMAL_RERUN:-}" ] && [ -f "$MEMO/$k" ]; then
      cp "$MEMO/$k" "$RUNS/$name.out"
      touch "$MEMO/$k" "$RUNS/$name.remembered" "$RUNS/$name.done"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$1" "$2" "${5:--}" "$covered" >>"$RUNS/jobs"
    fi
    return 0
  fi
  # A pool that died leaves the run unfinished, which reads as a failure.
  local next=$((SECONDS + PROGRESS)) started workers progress
  while [ ! -f "$RUNS/$name.done" ] && kill -0 "$POOL" 2>/dev/null; do
    if [ "$SECONDS" -ge "$next" ]; then
      if read -r started workers 2>/dev/null <"$RUNS/$name.started"; then
        printf '  RUN  %s: %s workers, %ss elapsed\n' "$(basename "$1")" "$workers" "$((SECONDS - started))"
        progress="$(grep -E '^Progress|states generated' "$RUNS/$name.out" 2>/dev/null | tail -1 || true)"
        [ -z "$progress" ] || printf '       %s\n' "$progress"
      else
        printf '  WAIT %s: queued for workers\n' "$(basename "$1")"
      fi
      next=$((SECONDS + PROGRESS))
    fi
    sleep 0.2
  done
  if [ -f "$RUNS/$name.deferred" ]; then
    printf '  DEFER %-33s does not end before FORMAL_DEADLINE\n' "$(basename "$1")"
    DEFERRED="$DEFERRED $(basename "$1")"
    return 0
  fi
  local out; out="$(cat "$RUNS/$name.out" 2>/dev/null || true)"
  if [ -n "${COVERAGE:-}" ]; then
    mkdir -p "$COVERAGE"
    printf '%s\n' "$out" > "$COVERAGE/$(basename "$1" .cfg).log"
  fi
  if grep -qE "$3" <<<"$out"; then
    local mark=""
    # Only a run that behaved is kept (remember, as it ended), so a failure
    # always runs again.
    if [ -f "$RUNS/$name.remembered" ]; then mark=" (remembered)"; fi
    printf '  OK   %-34s %s%s\n' "$(basename "$1")" "$4" "$mark"
    printf 'RESULT\t%s\t%s\t%s\n' "$ordinal" "$name" "$kind"
    case "$kind" in
      holds) HOLDS=$((HOLDS + 1)) ;;
      reached) REACHED=$((REACHED + 1)) ;;
      caught) CAUGHT=$((CAUGHT + 1)) ;;
    esac
  else
    # TLC's error and what follows it, else the run's last lines.
    if grep -qE '^Error:' <<<"$out"; then
      grep -m1 -A40 -E '^Error:' <<<"$out"
    else
      echo "$out" | tail -30
    fi
    echo "FAIL: $(basename "$1") did not produce expected outcome ($4)" >&2
    FAILED="$FAILED $(basename "$1")"
  fi
}

# The first walk collects each run; the second reports it in the same order.
checks() {
ORDINAL=0
section "GOOD" "full composition holds"
expect kernel.cfg kernel.tla "No error has been found" "all properties hold"

section "NEGATIVE" "each mutation is caught"
expect kernel_conflict_repaint.cfg kernel.tla "Temporal properties were violated" \
  "bypass route → RepaintLiveness violated (liveness non-mix)"
expect kernel_conflict_evict.cfg kernel.tla "Inv_CurrentLoaded is violated" \
  "evict-current → Inv_CurrentLoaded violated (safety non-mix)"
expect kernel_conflict_contaminate.cfg kernel.tla "Inv_JarMatchesVisible is violated" \
  "contaminate → Inv_JarMatchesVisible violated (cookie-leak non-mix)"

section "POSITIVE" "each legal behavior is reachable (witness violated)"
expect kernel_reach_surface_attach.cfg kernel.tla "Reach_SurfaceAttach is violated" \
  "a blank surface attach is reachable (RepaintLiveness not vacuous)"
expect kernel_reach_site_switch.cfg kernel.tla "Reach_SiteSwitch is violated" \
  "activating a non-initial site is reachable"
expect kernel_reach_evict_bg.cfg kernel.tla "Reach_EvictBackground is violated" \
  "evicting a backgrounded site is reachable"

section "ARCHIVE" "ARCH-001 byte-identity (2-safety via self-composition)"
expect archive.cfg archive.tla "No error has been found" \
  "app-tier state is byte-identical with/without archives"
expect archive_leak.cfg archive.tla "ByteIdentity is violated" \
  "leaking archive count into app-tier state is caught"
expect archive_reach.cfg archive.tla "Reach_Active is violated" \
  "byte-identity is checked against real archive+write activity (not vacuous)"

section "ARCHIVE_TRANSFER" "archive removal across separate durable stores"
expect archive_transfer.cfg archive_transfer.tla "No error has been found" \
  "transfers keep sites and collections without a visible duplicate"
expect archive_transfer_empty.cfg archive_transfer.tla "No error has been found" \
  "a site-only archive can be reclaimed without loss"
expect archive_transfer_drop_site.cfg archive_transfer.tla "NoLostSites is violated" \
  "dropping the archived site before the app write is caught"
expect archive_transfer_duplicate.cfg archive_transfer.tla "NoDuplicateVisible is violated" \
  "replaying the archived site after the app write is caught"
expect archive_transfer_drop_collection.cfg archive_transfer.tla "NoLostCollections is violated" \
  "dropping a collection before the app write is caught"
expect archive_transfer_touch_other.cfg archive_transfer.tla "OtherArchiveIntact is violated" \
  "wiping another archive's slot is caught"
expect archive_transfer_refuse_pending.cfg archive_transfer.tla "OpenCanEnd is violated" \
  "a close that refuses a move out whose save failed, never settling it, is caught"
expect archive_transfer_reach_partial.cfg archive_transfer.tla "Reach_Partial is violated" \
  "a partially transferred archive is reachable"
expect archive_transfer_reach_recovery.cfg archive_transfer.tla "Reach_SiteRecovery is violated" \
  "a site transfer can recover after a crash"
expect archive_transfer_reach_site_before_write.cfg archive_transfer.tla "Reach_SiteBeforeWrite is violated" \
  "a site transfer can recover before the app write"
expect archive_transfer_reach_removal_recovery.cfg archive_transfer.tla "Reach_RemovalRecovery is violated" \
  "a collection transfer can recover after the app write"
expect archive_transfer_reach_removal_before_write.cfg archive_transfer.tla "Reach_RemovalBeforeWrite is violated" \
  "a collection transfer can recover before the app write"
expect archive_transfer_reach_removed.cfg archive_transfer.tla "Reach_Removed is violated" \
  "sites and collections can be transferred before slot removal"
expect archive_transfer_reach_empty_wiped.cfg archive_transfer.tla "Reach_EmptyWiped is violated" \
  "the final site can cause immediate empty-slot cleanup"
expect archive_transfer_reach_empty_reclaimed.cfg archive_transfer.tla "Reach_EmptyReclaimed is violated" \
  "opening an empty slot after a crash can reclaim it"
expect archive_transfer_reach_stalled.cfg archive_transfer.tla "Reach_Stalled is violated" \
  "a move out whose last save failed in process is reachable"

section "RENDERER" "BUG-002 dead-renderer recovery (PAUSE-013 + PAUSE-014)"
expect renderer.cfg renderer.tla "No error has been found" \
  "a visible dead renderer is always eventually recovered"
expect renderer_noprobe.cfg renderer.tla "Temporal properties were violated" \
  "without the probe, an offscreen kill leaves a stuck black screen (caught)"
expect renderer_reach.cfg renderer.tla "Reach_VisibleDead is violated" \
  "a visible dead renderer is reachable (Recovered not vacuous)"

section "WARMSTART" "BUG-001 warm-start white screen (PAUSE-020, Attempt 8)"
expect warmstart.cfg warmstart.tla "No error has been found" \
  "an attach-triggered nudge repaints every warm-start SurfaceView reattach"
expect warmstart_bug.cfg warmstart.tla "Temporal propert(y|ies).*violated" \
  "a reattach after the resume one-shot nudge drains is left blank (reproduced + caught)"
expect warmstart_reach.cfg warmstart.tla "Reach_LateReattach is violated" \
  "the late-reattach ordering is reachable (RepaintLiveness not vacuous)"
expect warmstart_proxy.cfg warmstart.tla "Temporal propert(y|ies).*violated" \
  "a proxy that may not fire leaves the reattach blank (gap #5: what a native attach callback removes)"

section "RELOADLATCH" "BUG-001 rapid-refresh white screen (PAUSE-027, Attempt 11)"
expect reloadlatch.cfg reloadlatch.tla "No error has been found" \
  "a bounded commit window repaints every commit that settles inside it"
expect reloadlatch_bug.cfg reloadlatch.tla "Temporal propert(y|ies).*violated" \
  "a one-shot latch spent by the aborted load leaves the replacement blank (reproduced + caught)"
expect reloadlatch_reach.cfg reloadlatch.tla "Reach_SpentLatch is violated" \
  "the spent-latch ordering is reachable (RepaintLiveness not vacuous)"

section "TOAST" "a snackbar and its delayed offer stay on their page"
expect toast_page_boundary.cfg toast_page_boundary.tla "No error has been found" \
  "visible and queued snackbars belong to the current page"
expect toast_page_boundary_keepvisible.cfg toast_page_boundary.tla "InvOwned is violated" \
  "keeping a visible snackbar across a page change is caught"
expect toast_page_boundary_keepqueue.cfg toast_page_boundary.tla "InvOwned is violated" \
  "letting a queued snackbar surface on another page is caught"
expect toast_page_boundary_staleoffer.cfg toast_page_boundary.tla "InvOffer is violated" \
  "a delayed confirmation from an old page is caught"
expect toast_page_boundary_ignoretab.cfg toast_page_boundary.tla "InvOffer is violated" \
  "a delayed confirmation after a tab switch is caught"
expect toast_page_boundary_ignoreversion.cfg toast_page_boundary.tla "InvOffer is violated" \
  "a delayed confirmation after switching away and back is caught"
expect toast_page_boundary_reachqueue.cfg toast_page_boundary.tla "Reach_Queued is violated" \
  "the snackbar queue is reachable"
expect toast_page_boundary_reachdropped.cfg toast_page_boundary.tla "Reach_Dropped is violated" \
  "a stale delayed confirmation is dropped"

section "ACTIVATION_TOAST" "snackbar ownership across activation and tab steps"
expect activation_toast.cfg activation_toast.tla "No error has been found" \
  "activation page changes clear visible and queued snackbars" "$MODEL"
expect activation_toast_keepvisible.cfg activation_toast.tla "Inv_ToastOwned is violated" \
  "keeping a visible snackbar across an activation step is caught" "$MODEL"
expect activation_toast_keepqueue.cfg activation_toast.tla "Inv_ToastOwned is violated" \
  "keeping a queued snackbar across an activation step is caught" "$MODEL"
expect activation_toast_staleoffer.cfg activation_toast.tla "Inv_ToastOffer is violated" \
  "an unguarded delayed tab confirmation is caught" "$MODEL"
expect activation_toast_ignoretab.cfg activation_toast.tla "Inv_ToastOffer is violated" \
  "a delayed tab confirmation ignoring its tab is caught" "$MODEL"
expect activation_toast_ignoreversion.cfg activation_toast.tla "Inv_ToastOffer is violated" \
  "a delayed tab confirmation ignoring its version is caught" "$MODEL"
expect activation_toast_reachsite.cfg activation_toast.tla "Reach_ToastSiteChange is violated" \
  "a real activation step changes the shown site" "$MODEL"
expect activation_toast_reachtab.cfg activation_toast.tla "Reach_ToastTabChange is violated" \
  "a real tab step changes the active tab" "$MODEL"
expect activation_toast_reachqueue.cfg activation_toast.tla "Reach_ToastQueued is violated" \
  "a snackbar is queued in the composed world" "$MODEL"
expect activation_toast_reachdropped.cfg activation_toast.tla "Reach_ToastDropped is violated" \
  "a stale confirmation is dropped in the composed world" "$MODEL"

section "PROXY" "mutual exclusion (Android serialises mismatched-proxy sites)"
expect proxy.cfg proxy.tla "No error has been found" \
  "every loaded site shares the active proxy"
expect proxy_mismatch.cfg proxy.tla "Inv_ProxyCoherent is violated" \
  "co-loading a mismatched-proxy site is caught"
expect proxy_reach.cfg proxy.tla "Reach_TwoLoaded is violated" \
  "two compatible sites can co-load (coherence not vacuous)"

section "PROXY" "per-site router (PROXY-013)"
expect proxy_router.cfg proxy.tla "No error has been found" \
  "every loaded site egresses through its own proxy, mismatched or not"
expect proxy_router_misattribute.cfg proxy.tla "Inv_EgressMatchesConfig is violated" \
  "routing one site through another's upstream is caught (shared auth cache)"
expect proxy_router_reach.cfg proxy.tla "Reach_MismatchedCoLoaded is violated" \
  "mismatched-proxy sites CAN co-load under the router (not vacuous)"
expect proxy_serialised_noconcurrency.cfg proxy.tla "No error has been found" \
  "and CANNOT co-load under PROXY-008 serialisation (same formula, both sides)"

section "PROXY" "hosted tabs follow the slot's identity (LIR-024)"
expect proxy_staleident.cfg proxy.tla "Inv_EgressMatchesConfig is violated" \
  "a background slot kept loaded under a mismatched identity is caught"
expect proxy_sitenotslot.cfg proxy.tla "Inv_EgressMatchesConfig is violated" \
  "serialising by the sites instead of their slot identities is caught"
expect proxy_hosted_reach.cfg proxy.tla "Reach_HostedCoLoaded is violated" \
  "a hosted slot co-loads with its host's own slot (not vacuous)"

section "PROCESS ROUTE" "the process-wide rule's claims, turns and releases (PROXY-008, BUG-037)"
expect process_route.cfg process_route.tla "No error has been found" \
  "a page always sends on its own route, and the rule lists only what runs"
expect process_route_readd.cfg process_route.tla "Inv_NoGhost is violated" \
  "a claim that always lists its occupant brings back one released meanwhile (caught)"
expect process_route_midwrite.cfg process_route.tla "Inv_NoGhost is violated" \
  "voiding a claim only during its write misses a release while it waits (caught)"
expect process_route_noturn.cfg process_route.tla "Inv_Covers is violated" \
  "writes that do not wait for the turn let a released site's write land last (caught)"
expect process_route_quietonly.cfg process_route.tla "Inv_Covers is violated" \
  "a vacate that ends before its webview's native destroy lets the rule move under its page (caught)"
expect process_route_reach_releasedmidwrite.cfg process_route.tla "Reach_ReleasedMidWrite is violated" \
  "a release during a write is reachable"
expect process_route_reach_voidedturn.cfg process_route.tla "Reach_VoidedTurn is violated" \
  "a turn that finds its claim voided is reachable"
expect process_route_reach_claimedagain.cfg process_route.tla "Reach_ClaimedAgain is violated" \
  "a site claiming again while its old claim waits is reachable"
expect process_route_reach_heldforgone.cfg process_route.tla "Reach_HeldForGone is violated" \
  "a vacate holding the turn for a page still sending, a claim on another route behind it, is reachable"

section "LOCK ORDER" "a lock's turn serves each waiter within the flows ahead of it (ISO-003, DNS-019)"
expect lock_order.cfg lock_order.tla "No error has been found" \
  "no waiter on the jar's or the DNS lists' turn is passed over more often than the flows ahead of it"
expect lock_order_outoforder.cfg lock_order.tla "Inv_Bounded is violated" \
  "a turn that goes to any flow waiting passes the first one over (caught)"
expect lock_order_reach_behindtwo.cfg lock_order.tla "Reach_BehindTwo is violated" \
  "a flow served from behind two others is reachable"

section "RELAY ROUTES" "the router relay's route tables and the challenges they answer (PROXY-034)"
expect relay_routes.cfg relay_routes.tla "No error has been found" \
  "the relay ends on the last table, and a challenge is refused only for a site it does not route"
expect relay_routes_unordered.cfg relay_routes.tla "Inv_Latest is violated" \
  "installs that do not wait for each other let an older table land last (caught)"
expect relay_routes_nowait.cfg relay_routes.tla "Inv_Refused is violated" \
  "a challenge answered as it arrives refuses a site whose route is in flight (caught)"
expect relay_routes_reach_refused.cfg relay_routes.tla "Reach_Refused is violated" \
  "a challenge refused for a site no table routes is reachable"
expect relay_routes_reach_waited.cfg relay_routes.tla "Reach_Waited is violated" \
  "a challenge that waited for its site's route is reachable"

section "RETENTION" "memory-pressure cascade + notification retention (PAUSE-006)"
expect retention.cfg retention.tla "No error has been found" \
  "current is never evicted, warm tabs go first and notification sites last (TAB-024)"
expect retention_starve.cfg retention.tla "Inv_NotifLast is violated" \
  "evicting a notification site before a normal one is caught"
expect retention_reach.cfg retention.tla "Reach_NormalEvicted is violated" \
  "a normal site is actually evicted (retention order not vacuous)"
expect retention_activefirst.cfg retention.tla "Inv_WarmFirst is violated" \
  "evicting an active view while a warm tab is loaded is caught (TAB-024)"

section "CONTAINERS" "per-site keyspace disjointness (no shared storage)"
expect containers.cfg containers.tla "No error has been found" \
  "the site → container binding is injective (per-site isolation)"
expect containers_alias.cfg containers.tla "Inv_Disjoint is violated" \
  "binding two sites to one container is caught"
expect containers_reach.cfg containers.tla "Reach_TwoCreated is violated" \
  "two sites are actually created (disjointness not vacuous)"
expect containers_ownermirror.cfg containers.tla "Inv_PostureMatchesContainer is violated" \
  "a hosted slot mirroring cookies to its owner is caught (LIR-018)"
expect containers_hosted_reach.cfg containers.tla "Reach_Hosted is violated" \
  "a slot actually runs as another site (posture check not vacuous)"

section "KIOSK" "locked shortcut session seals the shell (KIOSK-001/002/003)"
expect kiosk.cfg kiosk.tla "No error has been found" \
  "a kiosk-shortcut launch seals chrome + holds fullscreen"
expect kiosk_leak_fs.cfg kiosk.tla "Inv_LockedIsSealed is violated" \
  "exiting fullscreen while locked is caught"
expect kiosk_leak_chrome.cfg kiosk.tla "Inv_LockedIsSealed is violated" \
  "building the drawer while locked is caught"
expect kiosk_reach.cfg kiosk.tla "Reach_Locked is violated" \
  "a locked state is reachable (sealing not vacuous)"

section "STORE" "secure-storage write serialisation (no lost update)"
expect store_serial.cfg store_serial.tla "No error has been found" \
  "every completed read-modify-write's key stays persisted"
expect store_serial_lost.cfg store_serial.tla "Inv_NoLostUpdate is violated" \
  "an unlocked read-modify-write drops a concurrently-committed key (caught)"
expect store_serial_reach.cfg store_serial.tla "Reach_TwoDone is violated" \
  "two ops can both complete (no-lost-update not vacuous)"

section "SWITCHGUARD" "site-switch version guard vs structural mutation"
expect switchguard.cfg switchguard.tla "No error has been found" \
  "a superseded switch bails instead of activating the wrong site"
expect switchguard_noguard.cfg switchguard.tla "Inv_NoWrongActivation is violated" \
  "an unguarded commit after a mutation activates the wrong site (caught)"
expect switchguard_reach.cfg switchguard.tla "Reach_Bailed is violated" \
  "a mutation-during-switch bail is reachable (guard not vacuous)"

section "BACKUP IMPORT" "granular site, folder and reactivation selections"
expect backup_import.cfg backup_import.tla "No error has been found" \
  "every bounded selector combination, including empty backups, preserves import scope"
expect backup_import_runall.cfg backup_import.tla "Inv_ScriptConsent is violated" \
  "reactivating a script without per-site consent is caught"
expect backup_import_allfolders.cfg backup_import.tla "Inv_FolderScope is violated" \
  "importing unchosen folders is caught"
expect backup_import_empty_replace.cfg backup_import.tla "Inv_SiteScope is violated" \
  "replacing current sites with a chosen folder from an empty backup is caught"
expect backup_import_empty_reach.cfg backup_import.tla "Reach_EmptyFolder is violated" \
  "a chosen empty folder imports without a site"
expect backup_import_script_reach.cfg backup_import.tla "Reach_EnabledScript is violated" \
  "a consented per-site script can reactivate"
expect backup_import_empty_backup_reach.cfg backup_import.tla "Reach_EmptyBackupFolder is violated" \
  "an empty backup can add a chosen empty folder without removing current sites"
expect backup_import_empty_noscope_reach.cfg backup_import.tla "Reach_EmptyBackupNoScope is violated" \
  "an empty backup with no selected content leaves current sites and folders alone"

section "BACKUP REVIEW" "whole-webspace and per-site selection transitions"
expect backup_review.cfg backup_review.tla "No error has been found" \
  "overlapping and empty webspaces preserve selection and activation scope"
expect backup_review_drop_shared.cfg backup_review.tla "Inv_NoSharedSiteLost is violated" \
  "dropping a site shared with another chosen webspace is caught"
expect backup_review_shared_reach.cfg backup_review.tla "Reach_SharedKept is violated" \
  "a shared site survives deselecting one of its webspaces"
expect backup_review_empty_reach.cfg backup_review.tla "Reach_EmptyFolder is violated" \
  "an empty webspace can be selected without a site"

section "BACKUP SETTINGS" "app preference and global-script import scope"
expect backup_settings.cfg backup_settings.tla "No error has been found" \
  "preference keys and global scripts obey their independent choices"
expect backup_settings_allprefs.cfg backup_settings.tla "Inv_PrefScope is violated" \
  "applying preferences without app consent or site scope is caught"
expect backup_settings_global_without_consent.cfg backup_settings.tla "Inv_GlobalRunConsent is violated" \
  "reactivating a global script without consent is caught"
expect backup_settings_search_reach.cfg backup_settings.tla "Reach_SearchSkipped is violated" \
  "the search default is skipped when no site import is chosen"
expect backup_settings_global_reach.cfg backup_settings.tla "Reach_GlobalRuns is violated" \
  "a confirmed global script can run on its chosen site"

section "BACKUP CONFLICTS" "matching site and webspace identities"
expect backup_conflicts.cfg backup_conflicts.tla "No error has been found" \
  "selected identity collisions obey site, content, folder and global-script rules"
expect backup_conflicts_discard.cfg backup_conflicts.tla "Inv_SiteCollision is violated" \
  "discarding an unselected current site during partial import is caught"
expect backup_conflicts_content.cfg backup_conflicts.tla "Inv_ContentCollision is violated" \
  "overwriting unchecked content on a matching site is caught"
expect backup_conflicts_folder.cfg backup_conflicts.tla "Inv_FolderCollision is violated" \
  "replacing a matching folder instead of merging a partial import is caught"
expect backup_conflicts_global.cfg backup_conflicts.tla "Inv_NoGlobalCollision is violated" \
  "letting a retained site run a new global script under an old id is caught"
expect backup_conflicts_reuse_global.cfg backup_conflicts.tla "Inv_FreshGlobalIdentity is violated" \
  "reusing a backup global-script id that an archive may have opted into is caught"
expect backup_conflicts_keep_reach.cfg backup_conflicts.tla "Reach_KeepCurrent is violated" \
  "an unchecked matching site remains current"
expect backup_conflicts_merge_reach.cfg backup_conflicts.tla "Reach_MergeFolder is violated" \
  "partial import merges a matching folder's members"
expect backup_conflicts_replace_reach.cfg backup_conflicts.tla "Reach_ReplaceAll is violated" \
  "all-site import replaces the site and folder lists"
expect backup_conflicts_global_reach.cfg backup_conflicts.tla "Reach_GlobalDisabled is violated" \
  "a retained site's old global opt-in is cleared before library replacement"
expect backup_conflicts_fresh_global_reach.cfg backup_conflicts.tla "Reach_FreshGlobal is violated" \
  "an imported global script receives a fresh local id"

section "BACKUP EXTENSION CONFLICTS" "fingerprint relinking and per-site consent"
expect backup_extension_conflicts.cfg backup_extension_conflicts.tla "No error has been found" \
  "an existing extension is never overwritten or activated by an id collision"
expect backup_extension_conflicts_id.cfg backup_extension_conflicts.tla "Inv_Fingerprint is violated" \
  "relinking a different extension by id instead of fingerprint is caught"
expect backup_extension_conflicts_add.cfg backup_extension_conflicts.tla "Inv_AddConsent is violated" \
  "adding backup files without approval is caught"
expect backup_extension_conflicts_run.cfg backup_extension_conflicts.tla "Inv_SiteConsent is violated" \
  "running a linked extension without per-site consent is caught"
expect backup_extension_conflicts_overwrite.cfg backup_extension_conflicts.tla "Inv_NoOverwrite is violated" \
  "overwriting an installed extension during import is caught"
expect backup_extension_conflicts_relink_reach.cfg backup_extension_conflicts.tla "Reach_Relink is violated" \
  "identical installed files are relinked without adding a package"
expect backup_extension_conflicts_add_reach.cfg backup_extension_conflicts.tla "Reach_Add is violated" \
  "an approved carried package can be added"
expect backup_extension_conflicts_missing_reach.cfg backup_extension_conflicts.tla "Reach_Missing is violated" \
  "a missing reference remains inactive"

section "JAR" "legacy cookie jar never left empty on a superseded restore"
expect jar_nonempty.cfg jar_nonempty.tla "No error has been found" \
  "a nuked jar is always repopulated before returning to rest"
expect jar_nonempty_bail.cfg jar_nonempty.tla "Inv_JarRepopulated is violated" \
  "the post-nuke bail leaves the jar empty when superseded (caught)"
expect jar_nonempty_reach.cfg jar_nonempty.tla "Reach_Nuked is violated" \
  "the nuked jar-empty state is reachable (repopulation not vacuous)"

section "ACTIVATION" "switches, pressure, moves and the jar at await granularity"
# The worlds, witnesses and planted mistakes are values of the enums in
# test/formal_model/checks.dart, printed as one config each and listed in
# checks.tsv: config, expected line, label, mutant (empty for the model as
# printed). Read on its own descriptor, so nothing TLC reads takes a line.
# A world's holding check also records which actions it took, for the
# footprint gate after it.
# activation_runs: each check as its config, expected line, label and the
# library TLC reads, a mutant's modules in front of the printed ones.
if [ "$PASS" = collect ] && selected; then
  activation_runs | cut -f1,4 | python3 world_key.py --spec activation.tla --out "$RUNS/worlds"
fi
if [ "$PASS" = collect ] && [ "$MODE" != --plan ]; then rm -rf "$COVERAGE_DIR"; fi
while IFS=$'\t' read -r -u 3 cfg pattern label library; do
  cover=""
  if [ "$pattern" = "No error has been found" ]; then cover="$COVERAGE_DIR"; fi
  COVERAGE="$cover" expect "$cfg" activation.tla "$pattern" "$label" "$library"
done 3< <(activation_runs)

section "PROXY FAIL-CLOSED" "a proxied site never egresses directly"
expect proxy_failclosed.cfg proxy_failclosed.tla "No error has been found" \
  "a proxied site blanks the load rather than falling back to direct"
expect proxy_failclosed_leak.cfg proxy_failclosed.tla "Inv_NoDirectWhenProxied is violated" \
  "a proxied-but-unbuildable config falling back to direct is caught"
expect proxy_failclosed_reach.cfg proxy_failclosed.tla "Reach_Proxied is violated" \
  "a proxied egress is reachable (fail-closed not vacuous)"

section "TLS TRUST" "the trust prompt's pins, portal verdict and declines (TLS-002 to TLS-013)"
expect tls_trust.cfg tls_trust.tla "No error has been found" \
  "a rejected certificate passes only as the user accepted it, and never on a pin or a prompt in a portal"
expect tls_trust_hosts.cfg tls_trust.tla "No error has been found" \
  "a decline stands for every host, and one certificate has one prompt at a time"
expect tls_trust_anyfp.cfg tls_trust.tla "Inv_PassPinned is violated" \
  "a pin that matches its host whatever the certificate is caught"
expect tls_trust_pinonopen.cfg tls_trust.tla "Inv_PinAccepted is violated" \
  "a pin written as the prompt opens, before the answer, is caught"
expect tls_trust_latecache.cfg tls_trust.tla "Inv_LateAnswer is violated" \
  "a late answer pinning the certificate another view cached since is caught"
expect tls_trust_noportal.cfg tls_trust.tla "Inv_NoWebPinPassInPortal is violated" \
  "a pin honoured without reading the portal verdict is caught (TLS-012)"
expect tls_trust_staleverdict.cfg tls_trust.tla "Inv_NoAskInPortal is violated" \
  "a verdict read as the handshake arrived, not at the read, is caught (TLS-012)"
expect tls_trust_forget.cfg tls_trust.tla "Inv_DeclinedNotAsked is violated" \
  "a decline not remembered is caught (TLS-013)"
expect tls_trust_noasking.cfg tls_trust.tla "Inv_OneAtATime is violated" \
  "a second prompt for a certificate already asked about is caught (TLS-002)"
expect tls_trust_answerunread.cfg tls_trust.tla "Inv_NoPinInPortal is violated" \
  "an Accept landing after the OS reports a portal, the verdict not read again, is caught (TLS-012)"
expect tls_trust_sharedcache.cfg tls_trust.tla "Inv_ShownOwn is violated" \
  "one certificate cache shared by every view of a host is caught (SEC-054)"
expect tls_trust_dartnoverdict.cfg tls_trust.tla "Inv_NoDartPinOnPortal is violated" \
  "a Dart client honouring a pin without the last verdict is caught (SEC-055)"
expect tls_trust_reach_pinused.cfg tls_trust.tla "Reach_PinUsed is violated" \
  "a pinned certificate lets a later webview handshake through"
expect tls_trust_reach_dartpinused.cfg tls_trust.tla "Reach_DartPinUsed is violated" \
  "a pinned certificate lets a Dart client's handshake through (TLS-004)"
expect tls_trust_reach_lateanswer.cfg tls_trust.tla "Reach_LateAnswerPinned is violated" \
  "an answer landing after its view went away pins what it showed"
expect tls_trust_reach_pinheldinportal.cfg tls_trust.tla "Reach_PinHeldInPortal is violated" \
  "a pinned certificate is held back while the OS reports a portal"
expect tls_trust_reach_declinedquiet.cfg tls_trust.tla "Reach_DeclinedQuiet is violated" \
  "a declined certificate met again is cancelled without a prompt"
expect tls_trust_reach_coalesced.cfg tls_trust.tla "Reach_Coalesced is violated" \
  "a certificate met while its prompt is open is cancelled without another"
}

activation_runs() {
  local cfg pattern label mutant
  while IFS=$'\t' read -r cfg pattern label mutant; do
    printf '%s\t%s\t%s\t%s\n' "$MODEL/checks/$cfg.cfg" "$pattern" "$label" \
      "${mutant:+$MODEL/mutants/$mutant:}$MODEL"
  done <"$MODEL/checks.tsv"
}

gates() {
  SECTION=ACTIVATION
# FOOTPRINT_WRITE=1 rewrites the list of pairs checked apart from this run.
if reporting && ! python3 footprint.py --model "$MODEL" --coverage "$COVERAGE_DIR" \
    --debt footprint_debt.tsv ${FOOTPRINT_WRITE:+--write} | sed 's/^/  /'; then
  echo "FAIL: the footprint gate" >&2
  exit 1
fi
if reporting; then
  # Every mistake footprint.py can plant (its --plants) fails the gate.
  plants=$(python3 footprint.py --plants)
  [ -n "$plants" ] || { echo "FAIL: footprint.py lists no plants" >&2; exit 1; }
  while IFS=$'\t' read -r plant what; do
    rc=0
    python3 footprint.py --model "$MODEL" --coverage "$COVERAGE_DIR" \
        --debt footprint_debt.tsv --plant "$plant" >/dev/null || rc=$?
    case "$rc" in
      10) echo "  OK   planted: $what is caught by the footprint gate" ;;
      3) echo "  --   planted: $what: this model has nothing to plant it in" ;;
      *) echo "FAIL: the footprint gate passed $what (exit $rc)" >&2; exit 1 ;;
    esac
  done <<< "$plants"
  # The world keys move for exactly the runs a change can reach.
  if ! activation_runs | cut -f1,4 | python3 world_key.py --spec activation.tla --self-test |
      sed 's/^/  /'; then
    echo "FAIL: the world key's self-test" >&2
    exit 1
  fi
  for plant in cut whole; do
    if activation_runs | cut -f1,4 |
        python3 world_key.py --spec activation.tla --self-test --plant "$plant" >/dev/null; then
      echo "FAIL: the world key's self-test passed a key planted with $plant" >&2
      exit 1
    fi
  done
  echo "  OK   planted: a key that cuts a world's action, and one that keeps every module whole, are caught by its self-test"
fi

section "TRACE CONFORMANCE" "code stayed inside the model"
case "$JAR" in /*) JAR_ABS="$JAR" ;; *) JAR_ABS="$(pwd)/$JAR" ;; esac
if reporting; then TLA2TOOLS_JAR="$JAR_ABS" ./trace/check_trace.sh | sed 's/^/  /'; fi
}

if [ "$MODE" = --gates ]; then
  PASS=report
  gates
  exit 0
fi

if [ "$SHARD_COUNT" -gt 1 ] && [ "$MODE" != --plan ]; then
  PASS=list
  checks
  python3 -I proofs/proof_shards.py assign --shard "$SHARD" --times tlc_times.tsv \
    $(cat "$RUNS/all") >"$RUNS/mine"
  PASS=collect
fi
checks
printf 'PLANNED\t%s\n' "$ORDINAL" >>"$MANIFEST"
[ "$MODE" != --plan ] || exit 0
pool &
POOL=$!
PASS=report
checks

echo "TALLY holds=$HOLDS caught=$CAUGHT reached=$REACHED"
if [ -n "$FAILED" ]; then echo "FAIL: did not behave:$FAILED" >&2; exit 1
elif [ -n "$DEFERRED" ]; then
  echo "DEFERRED past FORMAL_DEADLINE:$DEFERRED; run again, each run that ended is remembered" >&2
  exit 3
elif [ "$ORDINAL" -eq 0 ]; then echo "FAIL: no section is named $ONLY" >&2; exit 1
elif [ -n "$ONLY" ]; then echo "Section $ONLY behaved as expected."
elif [ "$SHARD_COUNT" -gt 1 ]; then echo "Model shard $SHARD behaved as expected."
else echo "All formal checks behaved as expected."; fi

if [ "${FORMAL_DEFER_GATES:-0}" != 1 ]; then gates; fi
