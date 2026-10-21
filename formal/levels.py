"""Holds a verify.sh run to the floor in formal/levels.tsv: every count of
what was checked (models that hold, planted mistakes caught, witnesses
reached, traces and steps replayed, proof obligations discharged) must reach
its line. A count above its line is printed, to be committed as the new
floor, so verification only grows.

usage: levels.py <floor.tsv> --models <log> --steps <log> --proofs <log>
                 --out <levels.tsv> [--plant]

--plant raises every floor by one and must fail: the gate is not vacuous.
"""
import argparse
import re
import sys


def counts(models, steps, proofs):
    tally = re.findall(r"^TALLY holds=(\d+) caught=(\d+) reached=(\d+)$",
                       models, re.M)
    if len(tally) != 1:
        sys.exit("levels: check.sh printed %d tallies, not one" % len(tally))
    holds, caught, reached = (int(n) for n in tally[0])
    replayed = [int(n) for n in
                re.findall(r"^  OK   \S+ +(\d+) steps, \d+ states replayed(?: \(remembered\))?$",
                           steps, re.M)]
    proved = [int(n) for n in
              re.findall(r"OK: (\d+) obligations? proved", proofs)]
    return {
        "holds": holds,
        "caught": caught,
        "reached": reached,
        "traces": len(replayed),
        "steps": sum(replayed),
        "modules": len(proved),
        "obligations": sum(proved),
    }


def floor(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                key, value = line.split("\t")
                out[key] = int(value)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("floor")
    p.add_argument("--models", required=True)
    p.add_argument("--steps", required=True)
    p.add_argument("--proofs", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--plant", action="store_true")
    a = p.parse_args()
    read = lambda path: open(path).read()
    now = counts(read(a.models), read(a.steps), read(a.proofs))
    want = floor(a.floor)
    if a.plant:
        want = {k: v + 1 for k, v in want.items()}
    missing = sorted(set(want) ^ set(now))
    if missing:
        sys.exit("levels: %s named on one side only" % ", ".join(missing))
    with open(a.out, "w") as f:
        for key, value in now.items():
            f.write("%s\t%d\n" % (key, value))
    fell = [k for k in now if now[k] < want[k]]
    for key in now:
        mark = "FELL" if key in fell else ("rose" if now[key] > want[key] else "  ok")
        print("  %s %-12s %8d  (floor %d)" % (mark, key, now[key], want[key]))
    if fell:
        sys.exit("levels: %s fell below formal/levels.tsv" % ", ".join(fell))
    if any(now[k] > want[k] for k in now):
        print("  a count rose: commit %s as formal/levels.tsv" % a.out)


main()
