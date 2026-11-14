"""Holds a verify.sh run to the floor in formal/levels.tsv: every count of
what was checked (models that hold, planted mistakes caught, witnesses
reached, traces replayed, the states the full schedule search reaches in the
sample worlds, proof obligations discharged) must reach its line. A count
above its line is printed, to be committed as the new floor, so verification
only grows.

The replayed steps are printed, not floored: they count the reduced search's
schedules, which fall whenever the reduction learns a footprint. A fall of
more than STEPS_SLACK under the same printed footprints warns, since only a
change in the code's schedules, not in the reduction, explains it.

usage: levels.py <floor.tsv> --models <log> --steps <log> --proofs <log>
                 --reached <log> --footprints <tsv> --out <levels.tsv> [--plant]

--plant raises every floor by one and must fail: the gate is not vacuous.
"""
import argparse
import hashlib
import os
import re
import sys

STEPS_SLACK = 0.03
# Printed and committed, never floored.
SOFT = ("steps", "footprints")


def reached_counts(reached):
    rows = re.findall(r"^REACHED (.+?)\tends=(\d+)\tstates=(\d+)\truns=\d+$",
                      reached, re.M)
    if not rows:
        sys.exit("levels: the schedules reported no sample world (reached.log)")
    names = [name for name, _, _ in rows]
    if len(set(names)) != len(names):
        sys.exit("levels: a sample world reported twice: %s" % sorted(names))
    return (sum(int(e) for _, e, _ in rows), sum(int(s) for _, _, s in rows))


def counts(models, steps, proofs, reached):
    tally = re.findall(r"^TALLY holds=(\d+) caught=(\d+) reached=(\d+)$",
                       models, re.M)
    if len(tally) != 1:
        sys.exit("levels: check.sh printed %d tallies, not one" % len(tally))
    holds, caught, witnessed = (int(n) for n in tally[0])
    replayed = [int(n) for n in
                re.findall(r"^  OK   \S+ +(\d+) steps, \d+ states replayed(?: \(remembered\))?$",
                           steps, re.M)]
    proved = [int(n) for n in
              re.findall(r"OK: (\d+) obligations? proved", proofs)]
    ends, states = reached_counts(reached)
    return {
        "holds": holds,
        "caught": caught,
        "reached": witnessed,
        "traces": len(replayed),
        "ends": ends,
        "states": states,
        "modules": len(proved),
        "obligations": sum(proved),
    }, {"steps": sum(replayed)}


def digest(path):
    if not os.path.exists(path):
        return "none"
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:16]


def floor(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                key, value = line.split("\t")
                out[key] = value if key == "footprints" else int(value)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("floor")
    p.add_argument("--models", required=True)
    p.add_argument("--steps", required=True)
    p.add_argument("--proofs", required=True)
    p.add_argument("--reached", required=True)
    p.add_argument("--footprints", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--plant", action="store_true")
    a = p.parse_args()
    read = lambda path: open(path).read()
    now, soft = counts(read(a.models), read(a.steps), read(a.proofs),
                       read(a.reached))
    soft["footprints"] = digest(a.footprints)
    want = floor(a.floor)
    hard = {k: v for k, v in want.items() if k not in SOFT}
    if a.plant:
        hard = {k: v + 1 for k, v in hard.items()}
    missing = sorted((set(hard) ^ set(now)) | (set(SOFT) - set(want)))
    if missing:
        sys.exit("levels: %s named on one side only" % ", ".join(missing))
    with open(a.out, "w") as f:
        for key, value in {**now, **soft}.items():
            f.write("%s\t%s\n" % (key, value))
    fell = [k for k in now if now[k] < hard[k]]
    for key in now:
        mark = "FELL" if key in fell else ("rose" if now[key] > hard[key] else "  ok")
        print("  %s %-12s %8d  (floor %d)" % (mark, key, now[key], hard[key]))
    same = soft["footprints"] == want["footprints"]
    print("  info steps        %8d  (last %d, %s footprints)"
          % (soft["steps"], want["steps"], "same" if same else "changed"))
    if same and soft["steps"] < want["steps"] * (1 - STEPS_SLACK):
        print("  WARN steps fell %.1f%% under the same footprints: the code's "
              "schedules shrank, not the reduction"
              % (100.0 * (want["steps"] - soft["steps"]) / want["steps"]))
    if fell:
        sys.exit("levels: %s fell below formal/levels.tsv" % ", ".join(fell))
    if any(now[k] > hard[k] for k in now) or soft != {k: want[k] for k in SOFT}:
        print("  a count moved: commit %s as formal/levels.tsv" % a.out)


main()
