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
# Backend timeouts are wall-clock, so a loaded CI runner can fail an obligation
# that a workstation proves. --stretch multiplies every timeout instead.
STRETCH="${TLAPM_STRETCH:-5}"

# Obligation count each module is known to discharge (the numbers in README.md).
# Matching "all obligations proved" alone is NOT a gate: "All 0 obligations
# proved." also matches, so a tlapm that silently checks nothing reads as green.
# Assert the count instead. Bump a number only when you add or remove proof steps.
min_obligations() {
  case "$1" in
    archive_identity.tla)      echo 25 ;;
    containers_disjoint.tla)   echo 23 ;;
    current_loaded.tla)        echo 52 ;;
    jar_matches.tla)           echo 52 ;;
    jar_repopulated.tla)       echo 28 ;;
    no_lost_update.tla)        echo 23 ;;
    proxy_coherent.tla)        echo 39 ;;
    proxy_failclosed_safe.tla) echo 28 ;;
    repaint_liveness.tla)      echo 72 ;;
    retention_safety.tla)      echo 22 ;;
    switch_guarded.tla)        echo 34 ;;
    # A new proof module is unpinned until someone records its count above.
    *)                         echo 1  ;;
  esac
}

ok=1
for f in *.tla; do
  echo "── $f ──"
  # Capture, then match: piping straight into `grep -q` lets grep exit on the
  # first hit and SIGPIPE tlapm, which `pipefail` then reports as a failure.
  out="$(tlapm -I "$KERNEL_DIR" --stretch "$STRETCH" "$f" 2>&1 || true)"
  proved="$(sed -nE 's/.*All ([0-9]+) obligations? proved.*/\1/p' <<<"$out" | tail -1)"
  want="$(min_obligations "$f")"
  if [ -n "$proved" ] && [ "$proved" -ge "$want" ]; then
    echo "  OK: $proved obligations proved (>= $want)"
  else
    echo "$out"
    if [ -n "$proved" ]; then
      echo "  FAIL: $f proved only $proved obligations, expected >= $want" >&2
    else
      echo "  FAIL: $f produced no 'all obligations proved' summary" >&2
    fi
    ok=0
  fi
done
[ "$ok" = 1 ] || exit 1
echo "All TLAPS proofs checked."
