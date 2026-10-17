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
# Backend timeouts are wall-clock, so a loaded CI runner can fail an obligation
# that a workstation proves. --stretch multiplies every timeout instead,
# tlapm's own as well: preparing one case of the printed tables' proof takes
# about 30 s on four cores, past the 25 s that a stretch of 5 allows, and a
# backend tlapm gives up on keeps running until memory runs out.
STRETCH="${TLAPM_STRETCH:-10}"
# One cache of fingerprints for every module, the printed ones too
# (TLAPM_CACHE_DIR moves it; CI keeps it between runs): an obligation proved
# before is not proved again. Fingerprints are per obligation, so an edit
# reproves only what it changed, and --safefp takes none another tlapm, zenon
# or Isabelle version wrote.
CACHE="${TLAPM_CACHE_DIR:-$(pwd)/.tlacache}"
# The modules share nothing and tlapm gains little from threads within one
# (activation_turns: 309 s on one, 274 s on four), so TLAPM_JOBS of them
# prove side by side, each with its share of the cores.
JOBS="${TLAPM_JOBS:-2}"
THREADS=$(( $(getconf _NPROCESSORS_ONLN) / JOBS ))
[ "$THREADS" -ge 1 ] || THREADS=1
prove() {
  tlapm -I "$KERNEL_DIR" ${FORMAL_MODEL:+-I "$FORMAL_MODEL"} --threads "$THREADS" \
    --cache-dir "$CACHE" --safefp --stretch "$STRETCH" "$@" 2>&1 || true
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
    activation_tables_proof.tla) echo 101 ;;
    activation_invariants_proof.tla) echo 287 ;;
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

# tlapm takes a lemma of an extended module as given, so the printed proofs
# (activation_tables_proof, the tables' cases of activation_turns) are checked here
# on their own.
work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT
check() {
  local f="$1" name out proved want
  name="$(basename "$f")"
  # Capture, then match: piping straight into `grep -q` lets grep exit on the
  # first hit and SIGPIPE tlapm, which `pipefail` then reports as a failure.
  out="$(prove "$f")"
  proved="$(obligations "$out")"
  want="$(min_obligations "$name")"
  # A failed obligation is fingerprinted too, and replayed without a retry,
  # so a module that fails is proved again ignoring the cache: a timeout on a
  # loaded machine does not fail every run after it.
  if [ -z "$proved" ] || [ "$proved" -lt "$want" ]; then
    out="$(prove --nofp "$f")"
    proved="$(obligations "$out")"
  fi
  if [ -n "$proved" ] && [ "$proved" -ge "$want" ]; then
    echo "  OK: $proved obligations proved (>= $want)" >"$work/$name.out"
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
}
# The printed proofs, the longest, start first.
for f in "$FORMAL_MODEL"/*_proof.tla *.tla; do
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
  check "$f" &
done
wait
ok=1
for f in *.tla "$FORMAL_MODEL"/*_proof.tla; do
  name="$(basename "$f")"
  echo "── $name ──"
  cat "$work/$name.out"
  if [ -e "$work/$name.failed" ]; then
    grep '  FAIL: ' "$work/$name.out" >&2
    ok=0
  fi
done
[ "$ok" = 1 ] || exit 1
echo "All TLAPS proofs checked."
