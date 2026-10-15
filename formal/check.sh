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
#   ACTIVATION activation*.cfg            -> activation.tla, with the modules the
#                                            code prints (FORMAL_MODEL); each
#                                            printed mutant MUST be caught
#   TRACE     trace/check_trace.sh        -> code stayed inside the model (LogService)
#
# Exit non-zero if any expectation is unmet. formal/verify.sh prints the
# modules and runs this; on its own it needs FORMAL_MODEL, the directory
# lib/formal_model/main.dart wrote (FORMAL_OUT). FORMAL_ONLY=<SECTION>
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
#
# A run whose inputs are byte for byte those of one that behaved before
# (for activation.tla, what of them its world can reach: world_key.py) is
# remembered there instead of run: it reports from the kept output, marked
# "(remembered)", and counts as the check it is (formal/README.md,
# "Remembered runs"). FORMAL_RERUN=1 runs every one.
set -euo pipefail

cd "$(dirname "$0")"

MODEL="${FORMAL_MODEL:-}"
if [ -z "$MODEL" ] || [ ! -f "$MODEL/activation_tables.tla" ]; then
  echo "FORMAL_MODEL names no printed modules; run formal/verify.sh" >&2
  exit 2
fi
MODEL="$(cd "$MODEL" && pwd)"

JAR="${TLA2TOOLS_JAR:-tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  # Retried, like the TLAPS fetch in the workflow: a single 504 from
  # GitHub's release-asset CDN otherwise takes the whole validate job down
  # before a single model runs. Observed four times across three PRs in one
  # afternoon (tla2tools twice, the Gradle distribution, fvm).
  #
  # `latest` rather than a pinned tag, which is a reproducibility hole this
  # repo would not otherwise accept. Pinning needs the current tag; resolve
  # it and switch this to
  # `https://github.com/tlaplus/tlaplus/releases/download/<tag>/tla2tools.jar`.
  curl -fsSL --retry 4 --retry-delay 2 -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

SLOTS="${FORMAL_SLOTS:-$(getconf _NPROCESSORS_ONLN)}"
[ "$SLOTS" -ge 1 ] 2>/dev/null || { echo "FORMAL_SLOTS is not a count of cores: $SLOTS" >&2; exit 2; }
CACHE="${FORMAL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/webspace-formal}"
TIMES="$CACHE/times" MEMO="$CACHE/memo"
mkdir -p "$TIMES" "$MEMO"
# A kept run no check has asked for in a fortnight is dropped.
find "$MEMO" -type f -mtime +14 -delete
# Everything a run writes, under states/ (beside the repo's files, not in a
# tmpfs: a state queue is gigabytes for the base config), gone as this ends.
mkdir -p states
RUNS="$(cd "$(mktemp -d states/run.XXXXXX)" && pwd)"
mkdir "$RUNS/facts"
: >"$RUNS/jobs"
POOL=""
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
# mean of those with one: a world the code has just grown may be long,
# but the base config, which reruns with most changes, is known to be.
plan() {
  local name job secs w cost
  while IFS=$'\t' read -r name job; do
    cost=-1
    if read -r secs w 2>/dev/null <"$TIMES/$name"; then cost=$((secs * w)); fi
    printf '%s\t%s\t%s\n' "$cost" "$name" "$job"
  done <"$RUNS/jobs" | awk -F'\t' -v OFS='\t' -v slots="$SLOTS" '
    { cost[NR] = $1; if ($1 > 0) { total += $1; known++ } name[NR] = $2
      sub(/^[^\t]*\t[^\t]*\t/, ""); job[NR] = $0 }
    END {
      cap = (NR > 1 && slots > 1) ? slots - 1 : slots
      mean = known ? total / known : 0
      for (i = 1; i <= NR; i++) {
        w = cost[i] > 0 ? int((slots * cost[i] + total - 1) / total) : 1
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
  local free="$SLOTS" running="" name w cfg spec lib cover
  while IFS=$'\t' read -r -u 4 name w cfg spec lib cover; do
    while [ "$free" -lt "$w" ]; do reap; done
    [ "$lib" != - ] || lib=""
    [ "$cover" != - ] || cover=""
    mkdir -p "$RUNS/$name.tmp"
    java "-Djava.io.tmpdir=$RUNS/$name.tmp" ${lib:+"-DTLA-Library=$lib"} -cp "$JAR" \
      tlc2.TLC -workers "$w" ${cover:+-coverage 100000} \
      -metadir "$RUNS/$name.states" -config "$cfg" "$spec" >"$RUNS/$name.out" 2>&1 &
    running="$running $!:$name:$w:$SECONDS"
    free=$((free - w))
  done 4< <(plan)
  while [ -n "$running" ]; do reap; done
}

# reap: marks done each run of the pool's that has ended, and keeps its time.
reap() {
  sleep 0.2
  local alive still="" entry pid name w t0 tmp
  alive=" $(jobs -rp | tr '\n' ' ') "
  for entry in $running; do
    IFS=: read -r pid name w t0 <<<"$entry"
    case "$alive" in *" $pid "*) still="$still $entry"; continue ;; esac
    rm -rf "$RUNS/$name.states" "$RUNS/$name.tmp"
    tmp="$(mktemp "$TIMES/.$name.XXXXXX")"
    echo "$((SECONDS - t0)) $w" >"$tmp" && mv "$tmp" "$TIMES/$name"
    remember "$name"
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
  grep -E "$(cat "$RUNS/$name.expect")" "$RUNS/$name.out" >/dev/null || return 0
  tmp="$(mktemp "$MEMO/.$name.XXXXXX")"
  cp "$RUNS/$name.out" "$tmp" && mv "$tmp" "$MEMO/$(cat "$RUNS/$name.key")"
}

PASS=collect
ONLY="${FORMAL_ONLY:-}"
SECTION=""
RAN=0
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
HOLDS=0 CAUGHT=0 REACHED=0 FAILED=""
expect() {
  selected || return 0
  local name; name="$(basename "$1" .cfg)"
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
  RAN=$((RAN + 1))
  # A pool that died leaves the run unfinished, which reads as a failure.
  while [ ! -f "$RUNS/$name.done" ] && kill -0 "$POOL" 2>/dev/null; do sleep 0.2; done
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
    case "$3" in
      "No error has been found") HOLDS=$((HOLDS + 1)) ;;
      Reach_*) REACHED=$((REACHED + 1)) ;;
      *) CAUGHT=$((CAUGHT + 1)) ;;
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

# The list: every run and gate, in the order they report. A run is an
# expect, which the first walk collects and the second reports; a gate
# runs in the second, after the runs before it.
checks() {
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
expect process_route_reach_releasedmidwrite.cfg process_route.tla "Reach_ReleasedMidWrite is violated" \
  "a release during a write is reachable"
expect process_route_reach_voidedturn.cfg process_route.tla "Reach_VoidedTurn is violated" \
  "a turn that finds its claim voided is reachable"
expect process_route_reach_claimedagain.cfg process_route.tla "Reach_ClaimedAgain is violated" \
  "a site claiming again while its old claim waits is reachable"

section "RETENTION" "memory-pressure cascade + notification retention (PAUSE-006)"
expect retention.cfg retention.tla "No error has been found" \
  "current is never evicted and notification sites are evicted last"
expect retention_starve.cfg retention.tla "Inv_NotifLast is violated" \
  "evicting a notification site before a normal one is caught"
expect retention_reach.cfg retention.tla "Reach_NormalEvicted is violated" \
  "a normal site is actually evicted (retention order not vacuous)"

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

section "JAR" "legacy cookie jar never left empty on a superseded restore"
expect jar_nonempty.cfg jar_nonempty.tla "No error has been found" \
  "a nuked jar is always repopulated before returning to rest"
expect jar_nonempty_bail.cfg jar_nonempty.tla "Inv_JarRepopulated is violated" \
  "the post-nuke bail leaves the jar empty when superseded (caught)"
expect jar_nonempty_reach.cfg jar_nonempty.tla "Reach_Nuked is violated" \
  "the nuked jar-empty state is reachable (repopulation not vacuous)"

section "ACTIVATION" "switches, pressure, moves and the jar at await granularity"
# The worlds, witnesses and planted mistakes are values of the enums in
# lib/formal_model/checks.dart, printed as one config each and listed in
# checks.tsv: config, expected line, label, mutant (empty for the model as
# printed). Read on its own descriptor, so nothing TLC reads takes a line.
# A world's holding check also records which actions it took, for the
# footprint gate after it.
# activation_runs: each check as its config, expected line, label and the
# library TLC reads, a mutant's modules in front of the printed ones.
activation_runs() {
  local cfg pattern label mutant
  while IFS=$'\t' read -r cfg pattern label mutant; do
    printf '%s\t%s\t%s\t%s\n' "$MODEL/checks/$cfg.cfg" "$pattern" "$label" \
      "${mutant:+$MODEL/mutants/$mutant:}$MODEL"
  done <"$MODEL/checks.tsv"
}
if [ "$PASS" = collect ] && selected; then
  activation_runs | cut -f1,4 | python3 world_key.py --spec activation.tla --out "$RUNS/worlds"
fi
rm -rf "$MODEL/coverage"
while IFS=$'\t' read -r -u 3 cfg pattern label library; do
  cover=""
  if [ "$pattern" = "No error has been found" ]; then cover="$MODEL/coverage"; fi
  COVERAGE="$cover" expect "$cfg" activation.tla "$pattern" "$label" "$library"
done 3< <(activation_runs)
# FOOTPRINT_WRITE=1 rewrites the list of pairs checked apart from this run.
if reporting && ! python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
    --debt footprint_debt.tsv ${FOOTPRINT_WRITE:+--write} | sed 's/^/  /'; then
  echo "FAIL: the footprint gate" >&2
  exit 1
fi
if reporting; then
  for plant in listed unlisted; do
    if ! python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
        --debt footprint_debt.tsv --plant "$plant" >/dev/null; then
      echo "  OK   planted: a $plant pair is caught by the footprint gate"
    elif [ "$plant" = listed ] || [ -n "$(grep -v '^#' footprint_debt.tsv)" ]; then
      echo "FAIL: the footprint gate passed a $plant pair planted in its list" >&2
      exit 1
    fi
  done
  # A table action that declares less than its text reads.
  if python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
      --debt footprint_debt.tsv --plant declared >/dev/null; then
    echo "FAIL: the footprint gate passed a read dropped from a declaration" >&2
    exit 1
  fi
  echo "  OK   planted: a read dropped from a declaration is caught by the footprint gate"
  # An action no world takes, left off the list of those none can.
  if python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
      --debt footprint_debt.tsv --plant untaken >/dev/null; then
    echo "FAIL: the footprint gate passed an action no world takes" >&2
    exit 1
  fi
  echo "  OK   planted: an action no world takes is caught by the footprint gate"
  # A table action that reads other flows' rows and declares none.
  if python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
      --debt footprint_debt.tsv --plant rows >/dev/null; then
    echo "FAIL: the footprint gate passed a row read dropped from a declaration" >&2
    exit 1
  fi
  echo "  OK   planted: a row read dropped from a declaration is caught by the footprint gate"
  # An invariant that declares less than its text reads.
  if python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
      --debt footprint_debt.tsv --plant invariant >/dev/null; then
    echo "FAIL: the footprint gate passed a read dropped from an invariant's declaration" >&2
    exit 1
  fi
  echo "  OK   planted: a read dropped from an invariant's declaration is caught by the footprint gate"
  # A need a world that takes the action does not give.
  if python3 footprint.py --model "$MODEL" --coverage "$MODEL/coverage" \
      --debt footprint_debt.tsv --plant needs >/dev/null; then
    echo "FAIL: the footprint gate passed a need a world that takes its action does not give" >&2
    exit 1
  fi
  echo "  OK   planted: a need no world that takes its action gives is caught by the footprint gate"
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

section "PROXY FAIL-CLOSED" "a proxied site never egresses directly"
expect proxy_failclosed.cfg proxy_failclosed.tla "No error has been found" \
  "a proxied site blanks the load rather than falling back to direct"
expect proxy_failclosed_leak.cfg proxy_failclosed.tla "Inv_NoDirectWhenProxied is violated" \
  "a proxied-but-unbuildable config falling back to direct is caught"
expect proxy_failclosed_reach.cfg proxy_failclosed.tla "Reach_Proxied is violated" \
  "a proxied egress is reachable (fail-closed not vacuous)"

section "TRACE CONFORMANCE" "code stayed inside the model"
case "$JAR" in /*) JAR_ABS="$JAR" ;; *) JAR_ABS="$(pwd)/$JAR" ;; esac
if reporting; then TLA2TOOLS_JAR="$JAR_ABS" ./trace/check_trace.sh | sed 's/^/  /'; fi
}

checks
pool &
POOL=$!
PASS=report
checks

echo "TALLY holds=$HOLDS caught=$CAUGHT reached=$REACHED"
if [ -n "$FAILED" ]; then echo "FAIL: did not behave:$FAILED" >&2; exit 1
elif [ "$RAN" -eq 0 ]; then echo "FAIL: no section is named $ONLY" >&2; exit 1
elif [ -n "$ONLY" ]; then echo "Section $ONLY behaved as expected."
else echo "All formal checks behaved as expected."; fi
