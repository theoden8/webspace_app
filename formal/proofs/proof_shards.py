"""Splits the TLAPS modules across proof shards and merges what they proved.

The modules share nothing, so a cold run's length is set by the runner that
proves the most. `assign` gives each shard its modules, longest first onto
the shard with the least so far, by the cold times in proof_times.tsv: every
shard reads the same file, so every shard computes the same split. A module
with no recorded time counts as the longest recorded one, so a new module is
never what a shard underestimates.

`merge` reads every shard's report and fails unless each shard reported once,
every module of the run was reported by exactly one of them with a proved
count, and the tables' step modules together prove at least TABLE_PARTS.
check_proofs.sh with a single shard merges its own report the same way, so
the rule has one owner.

usage: proof_shards.py assign --shard I/N --times proof_times.tsv <module.tla>...
       proof_shards.py merge --model DIR --proofs DIR <report>...
"""
import argparse
import os
import re
import sys

# The tables' step modules (activation_tables_<n>_proof) take eight steps
# each in the tables' order, so a step added before others moves them to the
# next module: their sum is pinned, which a new step only raises.
TABLE_PARTS = 1573
TABLE_PART = re.compile(r"activation_tables_\d+_proof\.tla")
HEADER = re.compile(r"^PROOF SHARD (\d+)/(\d+)$", re.M)
BLOCK = re.compile(r"^── (\S+\.tla) ──\n((?:(?!── ).*\n)*)", re.M)
PROVED = re.compile(r"^  OK: (\d+) obligations? proved", re.M)


def times(path):
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            name, secs = line.split("\t")[:2]
            out[name] = int(secs)
    return out


def assign(modules, *, shard, count, recorded):
    unknown = max(recorded.values(), default=1)
    cost = {m: recorded.get(os.path.basename(m), unknown) for m in modules}
    load = [0] * count
    mine = []
    for m in sorted(modules, key=lambda m: (-cost[m], os.path.basename(m))):
        to = min(range(count), key=lambda i: (load[i], i))
        load[to] += cost[m]
        if to == shard:
            mine.append(m)
    return mine


def merge(reports, *, modules):
    fails = []
    seen_shards, count = {}, None
    proved = {}
    for path in reports:
        text = open(path, encoding="utf-8").read()
        headers = HEADER.findall(text)
        if len(headers) != 1:
            fails.append(f"{path}: {len(headers)} shard headers, not one")
            continue
        at, n = map(int, headers[0])
        if count is None:
            count = n
        if n != count or at in seen_shards or not 0 <= at < n:
            fails.append(f"{path}: shard {at}/{n} repeats or does not fit {count}")
            continue
        seen_shards[at] = path
        for name, body in BLOCK.findall(text):
            if name in proved:
                fails.append(f"{name}: reported by two shards")
                continue
            m = PROVED.search(body)
            proved[name] = int(m.group(1)) if m else None
    if count is not None and set(seen_shards) != set(range(count)):
        fails.append(f"shards {sorted(set(range(count)) - set(seen_shards))} reported nothing")
    for name in sorted(modules):
        if name not in proved:
            fails.append(f"{name}: no shard proved it")
        elif proved[name] is None:
            fails.append(f"{name}: its shard reported no proved count")
    for name in sorted(set(proved) - set(modules)):
        fails.append(f"{name}: reported, and no module of the run")
    parts = sum(n or 0 for name, n in proved.items() if TABLE_PART.fullmatch(name))
    return fails, parts


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("assign")
    a.add_argument("--shard", required=True)
    a.add_argument("--times", required=True)
    a.add_argument("modules", nargs="*")
    m = sub.add_parser("merge")
    m.add_argument("--model", required=True)
    m.add_argument("--proofs", required=True)
    m.add_argument("reports", nargs="+")
    args = ap.parse_args()
    if args.cmd == "assign":
        at, n = map(int, args.shard.split("/"))
        if not 0 <= at < n:
            sys.exit(f"proof_shards: no shard {args.shard}")
        for path in assign(args.modules, shard=at, count=n,
                           recorded=times(args.times)):
            print(path)
        return 0
    modules = [f for f in os.listdir(args.model) if f.endswith("_proof.tla")]
    modules += [f for f in os.listdir(args.proofs) if f.endswith(".tla")]
    fails, parts = merge(args.reports, modules=modules)
    print("── the tables' step modules ──")
    if parts >= TABLE_PARTS:
        print(f"  OK: {parts} obligations in all (>= {TABLE_PARTS})")
    else:
        fails.append(f"the tables' step modules proved only {parts} "
                     f"obligations, expected >= {TABLE_PARTS}")
    if fails:
        for f in fails:
            print(f"  FAIL: {f}")
            print(f"  FAIL: {f}", file=sys.stderr)
        return 1
    print(f"  OK: {len(modules)} modules, each proved by one shard")
    print("All TLAPS proofs checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
