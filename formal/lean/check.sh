#!/usr/bin/env bash
# The Lean check (formal/lean/): the theorems on how a check of
# activation.tla may be split, built with no open proof, and, given the
# footprints lib/formal_model/main.dart prints, the decision that every
# invariant is checked in a world that takes its whole cone.
#
# usage: check.sh [<printed lean/Footprints.lean>]
# Needs lake (elan, which installs the version lean-toolchain names).
set -euo pipefail
cd "$(dirname "$0")"

# warningAsError fails a `sorry` already; grep too, so an option changed
# in lakefile.toml cannot let one through, nor a proof the compiler takes
# on trust.
if grep -rnE '\b(sorry|admit|native_decide)\b|^\s*axiom\b' --include='*.lean' Footprint Footprint.lean; then
  echo "FAIL: formal/lean leaves a proof open or taken on trust" >&2
  exit 1
fi
lake build --quiet
echo "  OK   formal/lean: commute, frame_preserves, cone, pairwise_unsound proved"

[ -n "${1:-}" ] || exit 0
printed="$1"
lake env lean "$printed"
echo "  OK   every invariant is checked in a world that takes its whole cone"

# Planted: worlds that allow no input take no invariant's cone, so the
# decision must fail.
planted="$(dirname "$printed")/planted/Footprints.lean"
mkdir -p "$(dirname "$planted")"
sed -E 's/^(  \| \.[A-Za-z0-9_]+ => )none$/\1some []/' "$printed" > "$planted"
if out="$(lake env lean "$planted" 2>&1)"; then
  echo "FAIL: the cone decision passed worlds that allow no input" >&2
  exit 1
fi
if ! grep -q 'footprints.everyInvariantLicensed = true' <<<"$out"; then
  echo "$out" >&2
  echo "FAIL: the planted footprints failed, but not at the cone decision" >&2
  exit 1
fi
echo "  OK   planted: worlds that allow no input are caught by the cone decision"
