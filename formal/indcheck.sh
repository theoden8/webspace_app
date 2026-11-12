#!/usr/bin/env bash
# Tries a candidate inductive invariant with TLC before any TLAPS work on it
# (Lamport, "Using TLC to Check Inductive Invariance"; the procedure is
# .claude/skills/inductive-invariant-check/SKILL.md). Three runs over one
# small world, each a falsifier:
#
#   init  Init => IndInv              INIT Init,   NEXT stop, INVARIANT IndInv
#         (stop is FALSE /\ Next: TLC takes no constant next-state action)
#   step  IndInv /\ Next => IndInv'   INIT IndInv, NEXT Next, INVARIANT IndInv
#   safe  IndInv => Inv               INIT IndInv, NEXT stop, INVARIANT Inv
#
# IndInv must enumerate: a TypeOK that bounds every variable to a finite set,
# conjuncts after it. A pass is evidence for the world it ran in, never a
# proof: nothing counts it, and no TLAPS step may cite it.
#
# usage: indcheck.sh <Module.tla> --ind IndInv --inv Inv
#                    [--init Init] [--next Next] [--constants world.cfg]
#                    [--search DIR]...
#        indcheck.sh --plant
# The constants file holds the world's CONSTANT lines as a .cfg writes them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
JAR="${TLA2TOOLS_JAR:-$HERE/tla2tools.jar}"
[ -f "$JAR" ] || { echo "indcheck: no TLC jar at $JAR (set TLA2TOOLS_JAR)" >&2; exit 2; }

# A proof module EXTENDS TLAPS, which the TLC jar lacks: tlapm's own library
# where tlapm is installed, else a module naming the backends and theorems
# tlapm's library/TLAPS.tla names, enough for TLC to parse the BY clauses it
# never evaluates.
tlaps_library() {
  local dir="$1" lib
  if command -v tlapm >/dev/null 2>&1; then
    lib="$(cd "$(dirname "$(command -v tlapm)")/.." && pwd)/lib/tlapm/stdlib"
    if [ -f "$lib/TLAPS.tla" ]; then echo "$lib"; return; fi
  fi
  mkdir -p "$dir/tlaps"
  {
    echo "---- MODULE TLAPS ----"
    for d in SimpleArithmetic SMT CVC3 CVC4 Yices veriT Zipper Z3 Spass LS4 PTL \
      Zenon Isa IsaWithSetExtensionality SlowZenon SlowerZenon VerySlowZenon \
      SlowestZenon Auto SlowAuto SlowerAuto SlowestAuto Force SlowForce \
      SlowerForce SlowestForce SlowestSimplifyAndSolve Simplification \
      SlowSimplification SlowestSimplification Blast SlowBlast SlowerBlast \
      SlowestBlast AutoBlast AllProvers AllSMT AllIsa ExpandENABLED ExpandCdot \
      AutoUSE Lambdify ENABLEDaxioms LevelComparison Trivial \
      PropositionalTemporalLogic; do echo "$d == TRUE"; done
    for d in SMTT CVC3T CVC4T YicesT veriTT ZipperT Z3T SpassT LS4T ZenonT IsaT \
      IsaM AllProversT AllSMTT AllIsaT; do echo "$d(X) == TRUE"; done
    echo "IsaMT(X, Y) == TRUE"
    for t in SetExtensionality NoSetContainsEverything RuleTLA1 RuleTLA2 RuleINV1 \
      RuleINV2 RuleWF1 RuleSF1 RuleWF2 RuleSF2 RuleInvImplication \
      RuleStepSimulation; do echo "THEOREM $t == TRUE"; done
    echo "===="
  } >"$dir/tlaps/TLAPS.tla"
  echo "$dir/tlaps"
}

run_checks() {
  local spec="$1" ind="$2" inv="$3" init="$4" next="$5" consts="$6" lib="$7"
  local dir name
  dir="$(mktemp -d)"
  name="$(basename "$spec" .tla)"
  cat >"$dir/IC_$name.tla" <<EOF
---- MODULE IC_$name ----
EXTENDS $name
IC_Stop == FALSE /\\ $next
====
EOF
  local failed=""
  for check in init step safe; do
    {
      [ -z "$consts" ] || cat "$consts"
      case "$check" in
        init) printf 'INIT %s\nNEXT IC_Stop\nINVARIANT %s\n' "$init" "$ind" ;;
        step) printf 'INIT %s\nNEXT %s\nINVARIANT %s\n' "$ind" "$next" "$ind" ;;
        safe) printf 'INIT %s\nNEXT IC_Stop\nINVARIANT %s\n' "$ind" "$inv" ;;
      esac
    } >"$dir/$check.cfg"
    if java -XX:+UseParallelGC "-Djava.io.tmpdir=$dir" \
        "-DTLA-Library=$(dirname "$spec")${lib:+:$lib}:$(tlaps_library "$dir")" \
        -cp "$JAR" tlc2.TLC \
        -deadlock -workers auto -metadir "$dir/$check.states" \
        -config "$dir/$check.cfg" "$dir/IC_$name.tla" >"$dir/$check.out" 2>&1 \
       && grep -q 'No error has been found' "$dir/$check.out"; then
      echo "  ok   $check"
    else
      echo "  FAIL $check: $(grep -m1 -E 'Error:|is violated' "$dir/$check.out" || echo 'see the TLC output')"
      sed -n '/Error:/,/^$/p' "$dir/$check.out" | head -40 | sed 's/^/       /'
      failed="${failed:+$failed }$check"
    fi
  done
  rm -rf "$dir"
  echo "${failed:-none}"
}

plant() {
  local dir out bad=0
  dir="$(mktemp -d)"
  cat >"$dir/Count.tla" <<'EOF'
---- MODULE Count ----
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = IF x < 2 THEN x + 1 ELSE x
Inv == x <= 2
Good == x \in 0..3 /\ x <= 2
Late == x \in 1..2
Gap == x \in {0, 2}
Loose == x \in 0..3
====
EOF
  for row in "Good none" "Late init" "Gap step" "Loose safe"; do
    set -- $row
    out="$(run_checks "$dir/Count.tla" "$1" Inv Init Next "" "" | tail -1)"
    if [ "$out" = "$2" ]; then
      echo "  OK   planted $1: fails $2"
    else
      echo "  FAIL planted $1: fails $out, expected $2"; bad=1
    fi
  done
  rm -rf "$dir"
  return "$bad"
}

if [ "${1:-}" = "--plant" ]; then plant; exit; fi
spec="${1:?usage: indcheck.sh <Module.tla> --ind IndInv --inv Inv}"; shift
ind="" inv="" init=Init next=Next consts="" lib=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ind) ind="$2"; shift 2 ;;
    --inv) inv="$2"; shift 2 ;;
    --init) init="$2"; shift 2 ;;
    --next) next="$2"; shift 2 ;;
    --constants) consts="$2"; shift 2 ;;
    --search) lib="${lib:+$lib:}$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "indcheck: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$ind" ] && [ -n "$inv" ] || { echo "indcheck: --ind and --inv are required" >&2; exit 2; }
result="$(run_checks "$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")" \
  "$ind" "$inv" "$init" "$next" "$consts" "$lib")"
printf '%s\n' "$result" | sed '$d'
if [ "$(printf '%s\n' "$result" | tail -1)" = none ]; then
  echo "  evidence only: $ind held in this world; prove it in TLAPS"
else
  exit 1
fi
