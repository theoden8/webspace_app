#!/usr/bin/env bash
# Machine-check the TLAPS proofs (unbounded-N, deductive).
#
# Requires tlapm (the TLA+ Proof Manager). It is a heavy dependency (~145 MB,
# bundles Isabelle), so this is NOT part of the default CI gate -- the TLC suite
# (../check.sh) is the fast gate; these proofs are the unbounded backstop. To
# install: download tlaps-1.5.0-x86_64-linux-gnu-inst.bin from
# github.com/tlaplus/tlapm/releases and run it with `-d <prefix>`, then add
# <prefix>/bin to PATH.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v tlapm >/dev/null 2>&1; then
  echo "SKIP: tlapm not on PATH (see header for install). Proofs not checked." >&2
  exit 0
fi

KERNEL_DIR="$(cd .. && pwd)"
ok=1
for f in *.tla; do
  echo "── $f ──"
  if tlapm -I "$KERNEL_DIR" "$f" 2>&1 | grep -qE "All [0-9]+ obligations proved"; then
    echo "  OK: all obligations proved"
  else
    echo "  FAIL: unproved obligations in $f" >&2
    ok=0
  fi
done
[ "$ok" = 1 ] || exit 1
echo "All TLAPS proofs checked."
