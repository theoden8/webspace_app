#!/usr/bin/env bash
# Machine-check the TLAPS proofs (unbounded-N, deductive).
#
# Requires tlapm (the TLA+ Proof Manager). Install the prebuilt tarball:
#
#   curl -fsSL -o /tmp/tlapm.tar.gz \
#     https://github.com/tlaplus/tlapm/releases/download/1.6.0-pre/tlapm-1.6.0-pre-x86_64-linux-gnu.tar.gz
#   tar -xzf /tmp/tlapm.tar.gz -C "$HOME"   # -> $HOME/tlapm/bin/tlapm
#   export PATH="$HOME/tlapm/bin:$PATH"
#
# Use the tarball, not the 1.5.0 `-inst.bin` installer: that installer compiles
# Isabelle/Pure with its bundled Poly/ML 5.4.0, which aborts on current Linux
# ("scanaddrs.cpp:107: Assertion `val.IsDataPtr()' failed", tlaplus/tlapm#88).
# The tarball ships prebuilt Isabelle heaps, so nothing is compiled on install.
# On macOS swap in tlapm-1.6.0-pre-arm64-darwin.tar.gz.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v tlapm >/dev/null 2>&1; then
  echo "SKIP: tlapm not on PATH (see header for install). Proofs not checked." >&2
  exit 0
fi

KERNEL_DIR="$(cd .. && pwd)"
# Some proofs are over the modules printed from the code (activation_turns).
if [ -z "${FORMAL_MODEL:-}" ] || [ ! -f "$FORMAL_MODEL/activation_tables.tla" ]; then
  echo "FORMAL_MODEL names no printed modules; run formal/verify.sh" >&2
  exit 2
fi
# Timeouts include preparing the SMT input, before the solver runs. With two
# cold preparations sharing a CPU, Plan_Ind hits the 50 s internal limit at
# stretch 10 and falls back to slower methods; at stretch 30 it prepares in
# 90 s and Z3 proves it in 0.2 s. Allow 150 s for preparation so a loaded
# runner does not redo whole modules after those avoidable timeouts.
STRETCH="${TLAPM_STRETCH:-30}"
# One cache of fingerprints for every module, the printed ones too
# (TLAPM_CACHE_DIR moves it; CI keeps it between runs): an obligation proved
# before is not proved again. Fingerprints are per obligation, so an edit
# reproves only what it changed, and --safefp takes none another tlapm, zenon
# or Isabelle version wrote.
CACHE="${TLAPM_CACHE_DIR:-$(pwd)/.tlacache}"
# A module's verdict is a function of tlapm and the modules it reads, which
# are files under the directories it searches (this one, the kernel's, the
# printed ones) or in tlapm's own library, which ships with the binary. So
# a module proved under the same bytes of all of them is remembered under
# MEMO, beside the fingerprints and kept with them: its output is read back,
# marked "(remembered)", instead of preparing every obligation again, which
# is most of a run even when each fingerprint hits. Only a module that
# proved what it must is kept, so a failure always runs again;
# FORMAL_RERUN=1 proves every one, and a kept module nothing has asked for
# in a fortnight is dropped. Paths are not part of the key.
MEMO="$CACHE/memo"
mkdir -p "$MEMO"
find "$MEMO" -type f -mtime +14 -delete
if command -v sha256sum >/dev/null 2>&1; then digest() { sha256sum "$@"; }
else digest() { shasum -a 256 "$@"; }; fi
INPUTS="$(
  digest <"$(command -v tlapm)" | sed 's/ .*/ tlapm/'
  digest *.tla | sed 's|  |  proofs/|'
  (cd "$KERNEL_DIR" && digest *.tla) | sed 's|  |  kernel/|'
  (cd "$FORMAL_MODEL" && digest *.tla) | sed 's|  |  model/|'
)"
key() { printf '%s\n' "$INPUTS" "module $1 --safefp" | digest | cut -d' ' -f1; }
# The modules share nothing and tlapm gains little from threads within one
# (activation_turns: 309 s on one, 274 s on four): it prepares each
# obligation on one thread, and that, not the backends, is most of a run.
# So TLAPM_JOBS of them, one a core by default, prove side by side.
JOBS="${TLAPM_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
THREADS=$(( $(getconf _NPROCESSORS_ONLN) / JOBS ))
[ "$THREADS" -ge 1 ] || THREADS=1
printf 'TLAPS: jobs=%s threads=%s timeout stretch=%s\n' "$JOBS" "$THREADS" "$STRETCH"
# A backend that times out has its shell killed, not the solver that shell
# started, which goes on proving beside the next modules until it ends on its
# own. So tlapm runs as a process group of its own (python3, as setsid is not
# on macOS), and whatever of the group outlives it goes with it; the exit trap
# takes the groups still running, which an interrupt no longer reaches.
prove() {
  local group
  python3 -c 'import os, sys; os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' \
    tlapm -I "$KERNEL_DIR" ${FORMAL_MODEL:+-I "$FORMAL_MODEL"} --threads "$THREADS" \
    --cache-dir "$CACHE" --safefp --stretch "$STRETCH" "$@" 2>&1 &
  group=$!
  touch "$work/groups/$group"
  wait "$group" || true
  kill -- -"$group" 2>/dev/null || true
  rm -f "$work/groups/$group"
}
obligations() { sed -nE 's/.*All ([0-9]+) obligations? proved.*/\1/p' <<<"$1" | tail -1; }

# Obligation count each module is known to discharge (the numbers in README.md).
# Matching "all obligations proved" alone is NOT a gate: "All 0 obligations
# proved." also matches, so a tlapm that silently checks nothing reads as green.
# Assert the count instead. Bump a number only when you add or remove proof steps.
min_obligations() {
  case "$1" in
    archive_identity.tla)      echo 25 ;;
    activation_turns.tla)      echo 43 ;;
    activation_tables_proof.tla) echo 341 ;;
    activation_invariants_checksOffScreen_proof.tla) echo 347 ;;
    activation_invariants_oneTabFlow_proof.tla) echo 446 ;;
    activation_types_proof.tla) echo 100 ;;
    activation_facts_vars_proof.tla) echo 68 ;;
    activation_facts_domains_proof.tla) echo 96 ;;
    activation_facts_members_proof.tla) echo 210 ;;
    activation_facts_fields_proof.tla) echo 96 ;;
    activation_types_steps_proof.tla) echo 92 ;;
    activation_held_steps_proof.tla) echo 276 ;;
    activation_supports_steps_proof.tla) echo 184 ;;
    # The tables' typing, held and supports modules are as many as their
    # rows need, so they are not pinned by name; formal/levels.tsv holds
    # the sum of them all. The tables' step modules are pinned by their sum
    # (TABLE_PARTS below).
    containers_disjoint.tla)   echo 39 ;;
    current_loaded.tla)        echo 52 ;;
    jar_matches.tla)           echo 52 ;;
    jar_repopulated.tla)       echo 28 ;;
    no_lost_update.tla)        echo 23 ;;
    proxy_coherent.tla)        echo 45 ;;
    proxy_failclosed_safe.tla) echo 28 ;;
    repaint_liveness.tla)      echo 72 ;;
    retention_safety.tla)      echo 22 ;;
    switch_guarded.tla)        echo 34 ;;
    # A new proof module is unpinned until someone records its count above.
    *)                         echo 1  ;;
  esac
}

# The tables' step modules (activation_tables_<n>_proof) take eight steps each
# in the tables' order, so a step added before others moves them to the next
# module: their sum is pinned, which a new step only raises.
TABLE_PARTS=1573

# tlapm takes a lemma of an extended module as given, so the printed proofs
# (activation_tables_proof, the tables' cases of activation_turns) are checked here
# on their own.
work="$(mktemp -d)"
mkdir "$work/groups"
reap() {
  local g
  for g in "$work"/groups/*; do
    [ ! -e "$g" ] || kill -- -"${g##*/}" 2>/dev/null || true
  done
  kill $(jobs -p) 2>/dev/null || true
  rm -rf "$work"
}
trap reap EXIT
# A module that falls short beside the others is proved again once they
# have ended, alone and ignoring the cache: a failed obligation is
# fingerprinted too, and replayed without a retry, so a timeout on a loaded
# machine does not fail every run after it; and tlapm holds every obligation
# it proves afresh until the module ends, so the modules beside one can take
# the memory it needs, and the kernel kills it.
check() {
  local f="$1" again="${2:-}" name out proved want start kept="" memo tmp
  name="$(basename "$f")"
  start=$(date +%s)
  case "$f" in
    "$FORMAL_MODEL"/*) memo="$MEMO/$(key "model/$name")" ;;
    *) memo="$MEMO/$(key "proofs/$name")" ;;
  esac
  if [ -z "$again" ] && [ -z "${FORMAL_RERUN:-}" ] && [ -f "$memo" ]; then
    echo "  $name: remembered"
    out="$(cat "$memo")"
    touch "$memo"
    kept=" (remembered)"
  else
    echo "  $name: started${again:+ again, alone and without the cache}"
    # Capture, then match: piping straight into `grep -q` lets grep exit on the
    # first hit and SIGPIPE tlapm, which `pipefail` then reports as a failure.
    out="$(prove ${again:+--nofp} "$f")"
  fi
  proved="$(obligations "$out")"
  want="$(min_obligations "$name")"
  if [ -n "$proved" ] && [ "$proved" -ge "$want" ]; then
    echo "  OK: $proved obligations proved (>= $want)$kept" >"$work/$name.out"
    if [ -z "$kept" ]; then
      tmp="$(mktemp "$MEMO/.$name.XXXXXX")"
      printf '%s\n' "$out" >"$tmp" && mv "$tmp" "$memo"
    fi
  elif [ -z "$again" ]; then
    echo "  $name: ${proved:-no} obligations proved after $(( $(date +%s) - start ))s, again once the rest end"
    echo "$f" >>"$work/again"
    return
  else
    {
      echo "$out"
      if [ -n "$proved" ]; then
        echo "  FAIL: $f proved only $proved obligations, expected >= $want"
      else
        echo "  FAIL: $f produced no 'all obligations proved' summary"
      fi
    } >"$work/$name.out"
    touch "$work/$name.failed"
  fi
  # The summary below prints once every module has ended, so a run the job's
  # timeout kills says nothing; each module says when it ends instead.
  # Not the summary's "OK: N obligations proved", which levels.py counts.
  local result="$proved proved$kept"
  [ ! -e "$work/$name.failed" ] || result=failed
  echo "  $name: $result in $(( $(date +%s) - start ))s"
}
# A printed steps module restates the lemmas it cites, omitted, instead of
# extending the modules that prove them: each is held to one proved here.
python3 omitted.py "$FORMAL_MODEL"/*_proof.tla *.tla
# The printed proofs, the longest, start first.
for f in "$FORMAL_MODEL"/*_proof.tla *.tla; do
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
  check "$f" &
done
wait
if [ -e "$work/again" ]; then
  while read -r f; do check "$f" again </dev/null; done <"$work/again"
fi
ok=1
parts=0
for f in "$FORMAL_MODEL"/activation_tables_[0-9]*_proof.tla; do
  n="$(sed -nE 's/^  OK: ([0-9]+) obligations.*/\1/p' "$work/$(basename "$f").out")"
  parts=$((parts + ${n:-0}))
done
for f in *.tla "$FORMAL_MODEL"/*_proof.tla; do
  name="$(basename "$f")"
  echo "── $name ──"
  cat "$work/$name.out"
  if [ -e "$work/$name.failed" ]; then
    grep '  FAIL: ' "$work/$name.out" >&2
    ok=0
  fi
done
echo "── the tables' step modules ──"
if [ "$parts" -ge "$TABLE_PARTS" ]; then
  echo "  OK: $parts obligations in all (>= $TABLE_PARTS)"
else
  short="  FAIL: the tables' step modules proved only $parts obligations, expected >= $TABLE_PARTS"
  echo "$short"
  echo "$short" >&2
  ok=0
fi
[ "$ok" = 1 ] || exit 1
echo "All TLAPS proofs checked."
