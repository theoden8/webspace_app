"""Holds the printed await counts (activation_awaits.tsv) to the ceilings in
formal/await_ceilings.tsv: no flow an input starts may take more awaits to
its end than its line says, no loop more awaits a round, and no input or loop
may appear that the file does not name. A count under its line is printed,
to be committed as the new ceiling, so a ceiling only falls.

A new await on a flow is a round trip to the platform, which every user of
that flow waits for: raising a line is a decision a reviewer sees in the
diff, never a side effect.

usage: await_ceilings.py <ceilings.tsv> <activation_awaits.tsv>
                         [--planted <tsv>] [--out <tsv>]

--planted names the printed counts of the tables with one more await on a
flow, which must fail: the gate is not vacuous.
"""
import argparse
import sys


def table(path):
    out = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3:
                sys.exit("await_ceilings: %s: a line has no loops column: %r"
                         % (path, line))
            name, awaits, loops = cols[0], int(cols[1]), cols[2]
            if name in out:
                sys.exit("await_ceilings: %s names %s twice" % (path, name))
            out[name] = (awaits, {} if loops == "-" else {
                at: int(n) for at, n in (l.split(":") for l in loops.split())
            })
    return out


def check(want, now):
    over, fell = [], []
    for name in sorted(set(want) | set(now)):
        if name not in now:
            over.append("%s is in the ceilings but no input of the tables" % name)
            continue
        if name not in want:
            over.append("%s is an input the ceilings do not name" % name)
            continue
        (cap, caps), (got, loops) = want[name], now[name]
        if got > cap:
            over.append("%s takes %d awaits to its end, over its ceiling %d"
                        % (name, got, cap))
        elif got < cap:
            fell.append(name)
        for at, n in sorted(loops.items()):
            if at not in caps:
                over.append("%s loops at %s, %d awaits a round, which the "
                            "ceilings do not name" % (name, at, n))
            elif n > caps[at]:
                over.append("%s loops at %s with %d awaits a round, over %d"
                            % (name, at, n, caps[at]))
            elif n < caps[at]:
                fell.append("%s@%s" % (name, at))
        for at in sorted(set(caps) - set(loops)):
            fell.append("%s@%s" % (name, at))
    return over, fell


def main():
    p = argparse.ArgumentParser()
    p.add_argument("ceilings")
    p.add_argument("printed")
    p.add_argument("--planted")
    p.add_argument("--out")
    a = p.parse_args()
    want, now = table(a.ceilings), table(a.printed)
    over, fell = check(want, now)
    if a.out:
        with open(a.printed) as src, open(a.out, "w") as dst:
            for line in src:
                cols = line.rstrip("\n").split("\t")
                dst.write(line if line.startswith("#") or len(cols) < 3
                          else "\t".join(cols[:3]) + "\n")
    for line in over:
        print("  OVER %s" % line)
    print("  %d inputs, %d over their ceiling, %d under it"
          % (len(now), len(over), len(fell)))
    if over:
        sys.exit("await_ceilings: a flow takes more awaits than "
                 "formal/await_ceilings.tsv allows")
    if fell:
        print("  a ceiling fell (%s): commit the printed counts as "
              "formal/await_ceilings.tsv" % " ".join(fell))
    if a.planted:
        caught, _ = check(want, table(a.planted))
        if not caught:
            sys.exit("await_ceilings: the tables with one more await passed, "
                     "so the gate is vacuous")
        print("  OK   planted: one more await is caught (%s)"
              % caught[0].split(" ", 1)[0])


main()
