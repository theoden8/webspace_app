"""Ablation of the printed tables' decisions over the security state: each
mutant forces one branch condition TRUE or FALSE, or drops one guard, of an
action that writes a variable a security invariant reads, and TLC runs it in
the cheapest world that takes the action first, then in every such world
before calling it a survivor.

Out of scope by construction: the place (`fl[f].pc`), `Calm` (decided from the
footprints, activation_calm.tsv), `Input` and the fresh flow number (the
scheduler), picks over the flow's own fields (`\\E s \\in fl[f]...`), a lock's
grant (`Jar!Granted`), and arms over a world constant (`IF ProxyRefused`,
`IF FALSE ...`): none of them is a decision the code makes about a site.

A survivor is a branch whose arms, or a guard whose absence, the invariants
cannot tell apart: a missing invariant or a redundant check. Each one is
labelled by hand in formal/ablation_survivors.tsv.

usage: ablate.py --model DIR --formal DIR --jar JAR [--times DIR]
                 [--only ACTION...] [--budget SECONDS] [--list]
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from world_key import Keys, tsv  # noqa: E402

SECURITY = {"jar", "stored", "signedIn", "loaded", "nested", "headless",
            "boxes", "gone", "ids", "told"}
ACTION = re.compile(r"^([A-Z]\w*)\(f\) ==\n(.*?)\n\n", re.S | re.M)
CONJUNCT = re.compile(r"^    /\\ (.*)$", re.M)
FRAMEWORK = ("fl[f].pc", "Calm", "Input", "f = inputs", "Jar!", "((", "\\E ")


def mutants(tables, writes):
    """Each mutant as (id, action, operator, the conjunct, its replacement)."""
    out = []
    for action, body in ACTION.findall(tables):
        if not writes.get(action, set()) & SECURITY:
            continue
        for line in CONJUNCT.findall(body):
            branch = re.match(r"(\(?IF )(.*)$", line)
            if branch:
                head, cond = branch.groups()
                if cond in ("ProxyRefused", "FALSE"):
                    continue
                for value in ("TRUE", "FALSE"):
                    out.append((f"{action}.{len(out)}.{value.lower()}", action,
                                f"force {value}", line, f"{head}{value}"))
            elif not line.startswith(FRAMEWORK):
                out.append((f"{action}.{len(out)}.drop", action, "drop", line, "TRUE"))
    return out


def apply(tables, action, line, replacement):
    m = next(m for m in ACTION.finditer(tables) if m.group(1) == action)
    block = m.group(0)
    old = f"    /\\ {line}\n"
    assert block.count(old) == 1, (action, line)
    return tables[:m.start()] + block.replace(old, f"    /\\ {replacement}\n") + tables[m.end():]


def worlds_taking(action, *, model, keys):
    expect = {r[0]: r[1] for r in tsv(os.path.join(model, "checks.tsv")) or ()}
    consts = {r[0]: set(r[1].split()) if len(r) > 1 else set()
              for r in tsv(os.path.join(model, "activation_worlds.tsv")) or ()}
    needs = keys.needs(model).get(action, set())
    return [w for w, c in consts.items()
            if expect.get(w) == "No error has been found"
            and all((n in c) == want for n, want in needs)]


def cost(world, times):
    try:
        secs, workers = open(os.path.join(times, world)).read().split()[:2]
        return int(secs) * int(workers)
    except (OSError, ValueError):
        return 10 ** 9


def tlc(lib, world, *, formal, jar):
    meta = os.path.join(lib, "states", world)
    os.makedirs(meta + ".tmp", exist_ok=True)
    t0 = time.time()
    r = subprocess.run(
        ["java", f"-Djava.io.tmpdir={meta}.tmp", f"-DTLA-Library={lib}", "-cp", jar,
         "tlc2.TLC", "-workers", "2", "-checkpoint", "0", "-metadir", meta,
         "-config", os.path.join(lib, "checks", world + ".cfg"), "activation.tla"],
        cwd=formal, capture_output=True, text=True)
    shutil.rmtree(os.path.join(lib, "states"), ignore_errors=True)
    if "No error has been found" in r.stdout:
        return "held", time.time() - t0
    if "Parsing or semantic analysis failed" in r.stdout:
        raise RuntimeError(f"{lib} does not parse in {world}: a tool fault, not a catch\n"
                           f"{r.stdout[-1500:]}")
    if "TLC threw an unexpected exception" in r.stdout:
        raise RuntimeError(f"TLC threw in {world} for {lib}: a tool fault, not a catch\n"
                           f"{r.stdout[-1500:]}")
    m = re.search(r"Invariant (\S+) is violated|(Deadlock reached)|Error: (.*)", r.stdout)
    if not m:
        raise RuntimeError(f"TLC gave no verdict for {lib} in {world}: a tool fault, "
                           f"not a catch\n{r.stdout[-400:]}{r.stderr[-400:]}")
    return next(g for g in m.groups() if g), time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--formal", required=True)
    ap.add_argument("--jar", required=True)
    ap.add_argument("--times", default=os.path.expanduser("~/.cache/webspace-formal/times"))
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--budget", type=int, default=36000)
    ap.add_argument("--work", default="states/ablate")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--resume", help="a tsv of verdicts already found; its mutants are skipped")
    a = ap.parse_args()
    model = os.path.abspath(a.model)
    a.jar = os.path.abspath(a.jar)
    tables = open(os.path.join(model, "activation_tables.tla")).read()
    writes = {r[0]: set(r[2].split()) for r in tsv(os.path.join(model, "activation_footprints.tsv")) or ()}
    keys = Keys(os.path.join(a.formal, "activation.tla"))
    all_mutants = [m for m in mutants(tables, writes) if not a.only or m[1] in a.only]
    if a.list:
        for mid, action, op, line, _ in all_mutants:
            print(f"{mid}\t{op}\t{line[:100]}\t{len(worlds_taking(action, model=model, keys=keys))} worlds")
        return 0
    spent = 0.0
    done = set()
    if a.resume and os.path.exists(a.resume):
        done = {r[0] for r in tsv(a.resume) or () if not r[2].startswith("not run")}
    else:
        print("# mutant\toperator\tverdict\tworld\tseconds")
    for mid, action, op, line, replacement in all_mutants:
        if mid in done:
            continue
        if spent > a.budget:
            print(f"{mid}\t{op}\tnot run: budget\t-\t0", flush=True)
            continue
        lib = os.path.abspath(os.path.join(a.work, mid))
        shutil.rmtree(lib, ignore_errors=True)
        shutil.copytree(model, lib)
        with open(os.path.join(lib, "activation_tables.tla"), "w") as f:
            f.write(apply(tables, action, line, replacement))
        worlds = sorted(worlds_taking(action, model=model, keys=keys), key=lambda w: cost(w, a.times))
        verdict, where, took = "SURVIVED", f"{len(worlds)} worlds", 0.0
        for w in worlds:
            v, secs = tlc(lib, w, formal=os.path.abspath(a.formal), jar=a.jar)
            took += secs
            if v != "held":
                verdict, where = v, w
                break
        spent += took
        shutil.rmtree(lib, ignore_errors=True)
        print(f"{mid}\t{op}\t{verdict}\t{where}\t{took:.0f}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
