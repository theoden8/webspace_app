#!/usr/bin/env python3
"""Replay the steps the code marked against formal/activation.tla.

Reads every <dir>/<config>.json that test/helpers/walk/step_traces.dart
wrote: the marks of every schedule test/activation_schedules_test.dart ran,
merged into a trie, each node a step (action, flow, outcome, site) and the
state the code was in after it. For each file it generates a module that
walks the model in lockstep with the trie, and TLC reports every node it
reaches: each must be reached, so every schedule the code ran is a run of
the model, step for step, ending in each step's state. Reached, not
followed from every state: a choice the model makes before the code shows
it (the cap's pick, named by the unload after it) leaves states that no
later step follows, and the run that made the code's choice goes on. Then,
over all files, coverage: every
(action, outcome) the model can take is taken by some schedule, unless
listed in steps_uncovered.tsv with its reason; a listed pair that is taken
fails too, so the list only shrinks.

The model is formal/activation.tla with the modules
test/formal_model/main.dart printed from the code into <model-dir>
(activation_steps, its Outcomes from ActivationStep; activation_tables).

A replay that behaved is kept under FORMAL_CACHE (Memo), and one whose
every input is byte for byte a kept one's is not run again: it reports
from what was kept, marked "(remembered)". FORMAL_RERUN=1 runs every one.

usage: check_steps.py <trace-dir> --model <model-dir> --jar <tla2tools.jar>
"""
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
FORMAL = os.path.dirname(HERE)
ROOT = os.path.dirname(FORMAL)
UNCOVERED = os.path.join(HERE, "steps_uncovered.tsv")


def tla_set(xs):
    return "{" + ", ".join(str(x) for x in xs) + "}"


def tla_seq(xs):
    return "<<" + ", ".join(xs) + ">>"


TAB_VARS = ["tabs", "active", "built", "hist", "queued", "file", "minted",
            "host", "link"]
ARCHIVE_VARS = ["gone", "views", "boxes"]


def boxed(trace):
    """Whether the trace's world follows webviews and containers: one with
    an archive to close or a site to delete (the model's `Boxed`)."""
    return bool(trace["boxed"])


def tla_state(s, max_tabs=1):
    core = ("rows |-> %s, loaded |-> %s, current |-> %d, version |-> %d, "
            "marker |-> [t |-> %d, v |-> %d], tier |-> %s, jar |-> %s, "
            "stored |-> %s, nested |-> %d, headless |-> %s, fore |-> %s, "
            "dns |-> [lvl |-> %d, levels |-> %s], told |-> %s") % (
        tla_seq(str(r) for r in s["rows"]), tla_set(s["loaded"]),
        s["current"], s["version"], s["marker"][0], s["marker"][1],
        tla_seq('"%s"' % t for t in s["tier"]), tla_set(s["jar"]),
        tla_seq(tla_set(x) for x in s["stored"]), s.get("nested", 0),
        tla_set(s.get("headless", [])),
        "TRUE" if s.get("fore", True) else "FALSE",
        s.get("dns", {}).get("lvl", 0),
        tla_set(s.get("dns", {}).get("levels", [])),
        tla_seq(str(t) for t in s.get("told", [-1] * len(s["tier"]))))
    if "tabs" in s:
        sites = len(s["tabs"])

        def padded(row, fill):
            return row + [fill] * (max_tabs - len(row))

        # A tab not yet made has no file, runs as its own site and follows
        # no link.
        core += (", tabs |-> %s, active |-> %s, built |-> %s, hist |-> %s, "
                 "queued |-> %s, file |-> %s, minted |-> %s, host |-> %s, "
                 "link |-> %s") % (
            tla_seq(tla_set(x) for x in s["tabs"]),
            tla_seq(str(x) for x in s["active"]),
            tla_seq(str(x) for x in s["built"]),
            tla_seq(str(x) for x in s["hist"]),
            tla_seq("[t |-> %d, h |-> %d]" % (q[0], q[1]) for q in s["queued"]),
            tla_seq(tla_seq(tla_seq(str(v) for v in by)
                            for by in padded(f, [0] * sites))
                    for f in s["file"]),
            tla_seq(str(x) for x in s["minted"]),
            tla_seq(tla_seq(str(v) for v in padded(h, i + 1))
                    for i, h in enumerate(s["host"])),
            tla_seq(tla_seq(str(v) for v in padded(l, 0))
                    for l in s["link"]))
    if "gone" in s:
        core += ", gone |-> %s, views |-> %s, boxes |-> %s" % (
            tla_set(s["gone"]), tla_set(s["views"]), tla_set(s["boxes"]))
    return "[" + core + "]"


def max_tabs(trace):
    """The model's TabIds: one past the most any site minted."""
    return 1 + max(max(s["minted"]) for s in trace["states"])




def model_vars(model_dir):
    """The model's variables, in the order activation_vars.tla declares them."""
    text = open(os.path.join(model_dir, "activation_vars.tla")).read()
    names = []
    for line in text.split("VARIABLES", 1)[1].splitlines()[1:]:
        m = re.match(r"\s+(\w+)", line)
        if not m:
            break
        names.append(m.group(1))
    return names


def module(name, trace, variables):
    nodes = trace["nodes"]
    kids = [[] for _ in nodes]
    roots = []
    for i, (parent, *_rest) in enumerate(nodes):
        (roots if parent < 0 else kids[parent]).append(i + 1)
    labels = tla_seq('[a |-> "%s", f |-> %d, o |-> "%s", s |-> %d]'
                     % (a, f, o, s) for _p, a, f, o, s, _st in nodes)
    return "\n".join([
        "---- MODULE %s ----" % name,
        "EXTENDS activation, TLC",
        "VARIABLE node",
        # Each constant the page sets, as the walk printed it; the base
        # module's definition gives the rest.
        *["Step%s == %s" % (k, v) for k, v in trace["constants"].items()],
        "StepMaxTabs == %d" % (max_tabs(trace) if trace["tabbed"] else 1),
        "S == %s" % tla_seq(tla_state(s, max_tabs(trace) if trace.get("tabbed") else 1)
                           for s in trace["states"]),
        "L == %s" % labels,
        "St == %s" % tla_seq(str(n[5] + 1) for n in nodes),
        "Kids == %s" % tla_seq(tla_set(k) for k in kids),
        "Roots == %s" % tla_set(roots),
        "Proj == [rows |-> rows, loaded |-> loaded, current |-> current,",
        "         version |-> version, marker |-> marker, tier |-> tier,",
        "         jar |-> jar, stored |-> stored, nested |-> nested,",
        "         headless |-> headless, fore |-> fore,",
        "         dns |-> dns, told |-> told%s%s]" % (
            "".join(", %s |-> %s" % (v, v) for v in TAB_VARS)
            if trace.get("tabbed") else "",
            "".join(", %s |-> %s" % (v, v) for v in ARCHIVE_VARS)
            if boxed(trace) else ""),
        "StepInit ==",
        "    \\E r \\in Roots :",
        "        /\\ node = r",
        "        /\\ rows = S[St[r]].rows /\\ loaded = S[St[r]].loaded",
        "        /\\ current = S[St[r]].current /\\ version = S[St[r]].version",
        "        /\\ marker = S[St[r]].marker /\\ tier = S[St[r]].tier",
        "        /\\ jar = S[St[r]].jar /\\ stored = S[St[r]].stored",
        "        /\\ nested = S[St[r]].nested",
        "        /\\ headless = S[St[r]].headless /\\ fore = S[St[r]].fore",
        "        /\\ dns = S[St[r]].dns /\\ told = S[St[r]].told",
        *(["        /\\ %s = S[St[r]].%s" % (v, v) for v in ARCHIVE_VARS]
          if boxed(trace) else [
            "        /\\ gone = {} /\\ views = {} /\\ boxes = {}"]),
        "        /\\ signedIn = {} /\\ holder = 0",
        "        /\\ queue = IF ColdStart /\\ ~Containers THEN << 0 >> ELSE << >>",
        "        /\\ fl = [f \\in Flows |-> NoFlow] /\\ inputs = 0",
        "        /\\ newest = 0 /\\ evictedShown = FALSE /\\ seen = {}",
        "        /\\ last = [a |-> \"init\", f |-> 0, o |-> \"\", s |-> 0]",
        *(["        /\\ %s = S[St[r]].%s" % (v, v) for v in TAB_VARS]
          if trace.get("tabbed") else [
            "        /\\ tabs = [s \\in Sites |-> {1}] /\\ active = [s \\in Sites |-> 1]",
            "        /\\ built = [s \\in Sites |-> 0] /\\ hist = built",
            "        /\\ queued = [s \\in Sites |-> NoQueued]",
            "        /\\ file = [s \\in Sites |-> [t \\in TabIds |-> [h \\in Sites |-> 0]]]",
            "        /\\ minted = [s \\in Sites |-> 1]",
            "        /\\ host = [s \\in Sites |-> [t \\in TabIds |-> s]]",
            "        /\\ link = [s \\in Sites |-> [t \\in TabIds |-> 0]]"]),
        # `minted` is the model's own pool bookkeeping, counted at the input
        # that mints, while the code's new tab shows only once it is listed
        # or saved: the model's count stands, the trace's is not held to it.
        # A spawned input's mark is the code's half of the step that spawned
        # it, whose action already started its flow: the model takes no step.
        "Folded == UNCHANGED << %s >>" % ", ".join(
            v for v in variables if v != "last"),
        "Follows(c) == (IF L[c].a \\in Spawned_Inputs THEN Folded ELSE Next)"
        " /\\ last' = L[c] /\\ Proj' = %s /\\ node' = c"
        % ("[S[St[c]] EXCEPT !.minted = minted']" if trace.get("tabbed")
           else "S[St[c]]"),
        "StepNext == \\E c \\in Kids[node] : Follows(c)",
        "Reached == PrintT(<<\"reached\", node>>)",
        "====", ""])


def merge_shards(paths, into):
    """One trace per configuration from the shards that recorded it: their
    tries joined as step_traces.dart builds one, a node by its parent, label
    and state, a state by its value. Returns the merged traces' paths."""
    by_config = {}
    for p in paths:
        by_config.setdefault(os.path.basename(p), []).append(p)
    out = []
    for name, group in sorted(by_config.items()):
        merged, states, state_at, nodes, node_at = None, [], {}, [], {}
        for p in group:
            t = json.load(open(p))
            if merged is None:
                merged = {k: t[k] for k in ("sites", "tabbed", "boxed", "constants")}
            assert all(merged[k] == t[k] for k in merged), \
                "the shards of %s disagree on its configuration" % name
            smap = []
            for st in t["states"]:
                key = json.dumps(st, sort_keys=True)
                if key not in state_at:
                    state_at[key] = len(states)
                    states.append(st)
                smap.append(state_at[key])
            nmap = []
            for nd in t["nodes"]:
                row = [nd[0] if nd[0] < 0 else nmap[nd[0]], *nd[1:5], smap[nd[5]]]
                key = json.dumps(row)
                if key not in node_at:
                    node_at[key] = len(nodes)
                    nodes.append(row)
                nmap.append(node_at[key])
        merged["states"], merged["nodes"] = states, nodes
        path = os.path.join(into, name)
        with open(path, "w") as f:
            json.dump(merged, f)
        out.append(path)
    return out


# A replay holds its whole trie as the module's constants beside the states
# it reaches: past this many nodes the longest outgrew the heap, so a larger
# trie is replayed in pieces.
PIECE = 200000


def pieces(nodes, limit=PIECE):
    """The trie's node indices in pieces of about [limit] each, every piece
    whole subtrees with the path from a root down to each, so every path
    of the trie is a path of some piece. A parent precedes its children."""
    size = [1] * len(nodes)
    kids = [[] for _ in nodes]
    roots = []
    for i in reversed(range(len(nodes))):
        parent = nodes[i][0]
        if parent >= 0:
            size[parent] += size[i]
    for i, nd in enumerate(nodes):
        (roots if nd[0] < 0 else kids[nd[0]]).append(i)
    whole, todo = [], list(reversed(roots))
    while todo:
        n = todo.pop()
        if size[n] <= limit:
            whole.append(n)
        else:
            todo.extend(reversed(kids[n]))
    out, group, filled = [], [], 0
    for n in whole:
        if group and filled + size[n] > limit:
            out.append(group)
            group, filled = [], 0
        group.append(n)
        filled += size[n]
    if group:
        out.append(group)
    result = []
    for group in out:
        keep = set()
        for top in group:
            n = nodes[top][0]
            while n >= 0 and n not in keep:
                keep.add(n)
                n = nodes[n][0]
            stack = [top]
            while stack:
                n = stack.pop()
                keep.add(n)
                stack.extend(kids[n])
        result.append(sorted(keep))
    return result


def piece_of(trace, keep):
    """The trace cut to the nodes [keep], renumbered in order."""
    index = {old: new for new, old in enumerate(keep)}
    nodes = trace["nodes"]
    return dict(trace, nodes=[
        [-1 if nodes[i][0] < 0 else index[nodes[i][0]]] + nodes[i][1:]
        for i in keep])


class Memo:
    """The replays that behaved, each kept by a hash of every byte its TLC
    run reads: its module and config, which hold the trace, each module in
    the directories TLC searches (formal/ and the printed model) and the jar
    its standard modules come from (README.md, "Remembered runs"). A run
    whose key is kept is not run again; one that runs is held to its key:
    each file TLC parsed is one the key read, so a module the key leaves out
    fails the replay instead of remembering it. [leave_out] names a
    directory the key does not read, the planted mistake that check
    catches."""

    def __init__(self, model, jar, keep, leave_out=None):
        cache = os.environ.get("FORMAL_CACHE") or os.path.expanduser(
            "~/.cache/webspace-formal")
        self.dir = os.path.join(cache, "replay")
        self.rerun = bool(os.environ.get("FORMAL_RERUN"))
        self.keep = keep
        os.makedirs(self.dir, exist_ok=True)
        stale = time.time() - 14 * 86400
        for kept in glob.glob(os.path.join(self.dir, "*")):
            if os.path.getmtime(kept) < stale:
                os.remove(kept)
        h = hashlib.sha256()
        self.read = set()
        self.searched = {os.path.realpath(d) for d in (FORMAL, model)}
        for i, d in enumerate((FORMAL, model)):
            if d == leave_out:
                continue
            for path in sorted(glob.glob(os.path.join(d, "*.tla"))):
                self.read.add(os.path.realpath(path))
                with open(path, "rb") as f:
                    h.update(b"%d/%s\0" % (i, os.path.basename(path).encode())
                             + f.read() + b"\0")
        with open(jar, "rb") as f:
            h.update(f.read())
        with zipfile.ZipFile(jar) as z:
            self.standard = {os.path.basename(n) for n in z.namelist()
                             if n.startswith("tla2sany/StandardModules/")
                             and n.endswith(".tla")}
        self.base = h.digest()

    def key(self, text, cfg):
        return hashlib.sha256(self.base + text.encode() + b"\0"
                              + cfg.encode()).hexdigest()

    def get(self, key):
        if self.rerun:
            return None
        path = os.path.join(self.dir, key)
        try:
            with open(path) as f:
                reached = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return None
        os.utime(path)
        return reached

    def unread(self, out, own):
        """The files TLC parsed that the key did not read, beside the run's
        own module and the jar's standard ones, which TLC unpacks outside
        the directories it searches."""
        own = os.path.realpath(own)
        searched = self.searched | {os.path.dirname(own)}
        return sorted(
            p for p in re.findall(r"^Parsing file (\S+)", out, re.M)
            if os.path.realpath(p) not in self.read | {own}
            and not (os.path.basename(p) in self.standard
                     and os.path.dirname(os.path.realpath(p)) not in searched))

    def put(self, key, reached):
        if not self.keep:
            return
        path = os.path.join(self.dir, key)
        tmp = "%s.%d" % (path, os.getpid())
        with open(tmp, "w") as f:
            json.dump(reached, f)
        os.replace(tmp, path)


def run_tlc(name, trace, jar, model, work, memo):
    """The nodes the replay of [trace] reached, numbered from 1, and None;
    or None and why TLC did not replay it. Third, whether it was kept."""
    text = module(name, trace, model_vars(model))
    cfg = ("CONSTANTS\n    Mistake = \"none\"\n    MaxInputs = 4\n"
           "    Allowed <- Inputs\n    MaxTabs <- StepMaxTabs\n"
           + "".join("    %s <- Step%s\n" % (k, k)
                     for k in trace["constants"])
           + "INIT StepInit\nNEXT StepNext\nCONSTRAINT Reached\n")
    key = memo.key(text, cfg)
    kept = memo.get(key)
    if kept is not None:
        return kept, None, True
    own = os.path.join(work, name + ".tla")
    with open(own, "w") as f:
        f.write(text)
    with open(os.path.join(work, name + ".cfg"), "w") as f:
        f.write(cfg)
    out = subprocess.run(
        ["java", "-XX:+UseParallelGC", "-XX:MaxRAMPercentage=50",
         "-DTLA-Library=" + os.pathsep.join([FORMAL, model]),
         "-cp", jar, "tlc2.TLC", "-deadlock",
         # A replay reaches only the states of one trace, but the trace is
         # a module of every step the schedules took: the longest no longer
         # fits the JVM's default quarter of memory beside TLC's default
         # fingerprint set, so the heap takes half and the set a twentieth.
         "-fpmem", "0.05",
         "-workers", "auto", "-metadir", os.path.join(work, "states", name),
         "-config", name + ".cfg", name + ".tla"],
        cwd=work, capture_output=True, text=True).stdout
    if "No error has been found" not in out:
        return None, "TLC did not run the replay:\n" + out[-3000:], False
    unread = memo.unread(out, own)
    if unread:
        return None, ("the replay's key did not read what TLC parsed, so it "
                      "would remember a run whose inputs changed:\n    "
                      + "\n    ".join(unread)), False
    reached = sorted({int(n) for n in re.findall(r'<<"reached", (\d+)>>', out)})
    memo.put(key, reached)
    return reached, None, False


def replay(path, jar, model, work, memo):
    trace = json.load(open(path))
    config = os.path.splitext(os.path.basename(path))[0]
    nodes = trace["nodes"]
    split = pieces(nodes)
    reached = set()
    remembered = True
    for k, keep in enumerate(split):
        name = "mc_steps_" + config + ("_%d" % k if len(split) > 1 else "")
        got, err, kept = run_tlc(name, piece_of(trace, keep), jar, model, work, memo)
        if err:
            return trace, err
        remembered = remembered and kept
        reached |= {keep[n - 1] for n in got}
    missed = [i for i, nd in enumerate(nodes)
              if i not in reached and (nd[0] < 0 or nd[0] in reached)]
    if not missed:
        print("  OK   %-16s %d steps, %d states replayed%s"
              % (config, len(nodes), len(trace["states"]),
                 " (remembered)" if remembered else ""))
        return trace, None
    at = nodes[missed[0]][0]
    path_to = []
    n = at
    while n >= 0:
        path_to.append(nodes[n])
        n = nodes[n][0]
    path_to.reverse()
    after = [nodes[i] for i in missed if nodes[i][0] == at]
    lines = ["%s: after these steps the model cannot take a step the code took"
             % config]
    for _p, a, f, o, s, st in path_to:
        lines.append("    %s#%d %s%s" % (a, f, o or "-", " site %d" % s if s else ""))
    lines.append("  one of the next steps the code took:")
    for _p, a, f, o, s, st in after:
        lines.append("    %s#%d %s%s -> %s" % (a, f, o or "-", " site %d" % s if s else "",
                                            json.dumps(trace["states"][st])))
    return trace, "\n".join(lines)


def model_outcomes(model):
    src = open(os.path.join(model, "activation_steps.tla")).read()
    body = re.search(r"Outcomes == \[(.*?)\]\n", src, re.S).group(1)
    return {a: set(re.findall(r'"([^"]*)"', os))
            for a, os in re.findall(r"(\w+) \|-> \{([^}]*)\}", body)}


def plant(path, work):
    """A copy of the trace at path cut to the path from its root to its first
    nuke, with that nuke leaving the jar full: a step the model cannot take,
    which the replay MUST catch. None when the trace has no nuke."""
    trace = json.load(open(path))
    nodes = trace["nodes"]
    at = next((i for i, n in enumerate(nodes) if n[1] == "RestoreNukeReply"), None)
    if at is None:
        return None
    keep = []
    while at >= 0:
        keep.append(at)
        at = nodes[at][0]
    keep.reverse()
    index = {old: new for new, old in enumerate(keep)}
    trace["states"].append(dict(trace["states"][nodes[keep[-1]][5]], jar=[1]))
    trace["nodes"] = [
        [index.get(nodes[i][0], -1)] + nodes[i][1:5]
        + [len(trace["states"]) - 1 if i == keep[-1] else nodes[i][5]]
        for i in keep]
    out = os.path.join(work, "planted")
    os.makedirs(out, exist_ok=True)
    planted = os.path.join(out, os.path.basename(path))
    json.dump(trace, open(planted, "w"))
    return planted


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--plant", action="store_true",
                    help="replay the first trace in <dir> with a nuke planted "
                         "to leave the jar full; the replay must refuse it")
    ap.add_argument("--plant-key", action="store_true",
                    help="replay the smallest trace in <dir> under a key that "
                         "does not read the printed model; the replay must "
                         "refuse to keep it")
    ap.add_argument("--model", required=True)
    ap.add_argument("--jar", required=True)
    args = ap.parse_args()
    failures = []
    model_dir = os.path.abspath(args.model)
    model = model_outcomes(model_dir)

    shards = sorted(glob.glob(os.path.join(args.dir, "**", "*.json"),
                              recursive=True))
    if not shards:
        failures.append("no step traces in %s" % args.dir)
    # Removed at exit, sys.exit included: a merge is as large as the traces.
    merged = tempfile.TemporaryDirectory()
    files = merge_shards(shards, into=merged.name)
    jar = os.path.abspath(args.jar)
    if args.plant:
        with tempfile.TemporaryDirectory() as work:
            planted = next((p for p in (plant(f, work) for f in files) if p), None)
            if planted is None:
                sys.exit("no trace in %s takes RestoreNukeReply" % args.dir)
            _trace, err = replay(planted, jar, model_dir, work,
                                 Memo(model_dir, jar, keep=False))
        if err:
            sys.exit(err)
        print("the planted nuke was not caught")
        return
    if args.plant_key:
        smallest = min(files, key=os.path.getsize)
        with tempfile.TemporaryDirectory() as work:
            _trace, err = replay(smallest, jar, model_dir, work,
                                 Memo(model_dir, jar, keep=False,
                                      leave_out=model_dir))
        if err:
            sys.exit(err)
        print("the key that does not read the printed model was not caught")
        return
    memo = Memo(model_dir, jar, keep=True)
    taken = set()
    with tempfile.TemporaryDirectory() as work:
        for path in files:
            trace, err = replay(path, jar, model_dir, work, memo)
            if err:
                failures.append(err)
            taken |= {(n[1], n[3]) for n in trace["nodes"] if n[1] != "start"}

    listed = {}
    for line in open(UNCOVERED):
        if line.strip() and not line.startswith("#"):
            a, o, reason = line.rstrip("\n").split("\t")
            listed[(a, "" if o == "-" else o)] = reason
    for a, outs in sorted(model.items()):
        for o in sorted(outs):
            key = (a, o)
            if key in taken and key in listed:
                failures.append("coverage: %s %s is taken now; drop it from "
                                "steps_uncovered.tsv" % (a, o or "-"))
            elif key not in taken and key not in listed:
                failures.append("coverage: no schedule takes %s %s; drive it or "
                                "list it with its reason" % (a, o or "-"))
            elif key in listed:
                print("    %-22s %-7s not taken: %s" % (a, o or "-", listed[key]))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print("Every marked step is a step of the model, and every branch is "
          "taken or listed.")


if __name__ == "__main__":
    main()
