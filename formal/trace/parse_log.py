#!/usr/bin/env python3
"""Convert a LogService trace into a TLC-checkable conformance module.

Reads the structured `[Subsystem/level] message` lines the app already emits and
projects them onto the kernel's observable variables (cur, loaded, jar). Emits a
self-contained `mc_<name>.tla` that EXTENDS conformance and a matching `.cfg`.

Handled log patterns (the seed schema -- extend as more transitions are modeled):
  "Switching to site N"                       -> pending activate to site N
  "After switch, loaded indices: {a, b}"      -> commit activate (cur=N, loaded set, jar=N)
  "Back gesture: navigated back"              -> surface event (no observable change)

The generated module is a derivative; check_trace.sh regenerates it.
"""
import re
import sys

SWITCH = re.compile(r"Switching to site (\d+)")
AFTER = re.compile(r"After switch, loaded indices:\s*\{([^}]*)\}")
BACK = re.compile(r"Back gesture: navigated back")


def parse_set(s):
    return sorted(int(x) for x in s.split(",") if x.strip())


def tla_set(xs):
    return "{" + ", ".join(str(x) for x in xs) + "}"


def parse(lines):
    # Initial observable state at startup: site 1 visible and loaded, its jar.
    cur, loaded, jar = 1, [1], 1
    trace = [dict(act="init", cur=cur, loaded=list(loaded), jar=jar)]
    pending = None
    for line in lines:
        m = SWITCH.search(line)
        if m:
            pending = int(m.group(1))
            continue
        m = AFTER.search(line)
        if m and pending is not None:
            cur = pending
            loaded = parse_set(m.group(1))
            jar = cur  # legacy capture-nuke-restore makes the jar follow the visible site
            trace.append(dict(act="activate", cur=cur, loaded=list(loaded), jar=jar))
            pending = None
            continue
        if BACK.search(line):
            trace.append(dict(act="surface", cur=cur, loaded=list(loaded), jar=jar))
    return trace


def emit(name, trace):
    recs = ",\n  ".join(
        "[act |-> \"%s\", cur |-> %d, loaded |-> %s, jar |-> %d]"
        % (r["act"], r["cur"], tla_set(r["loaded"]), r["jar"])
        for r in trace
    )
    tla = (
        "---- MODULE mc_%s ----\n"
        "EXTENDS conformance\n"
        "Trace == <<\n  %s\n>>\n"
        "VARIABLE t\n"
        "Init == t = 0\n"
        "Next == UNCHANGED t\n"
        "Spec == Init /\\ [][Next]_t\n"
        "Conforms == TraceConforms(Trace)\n"
        "ObsOK == ObsInvariants(Trace)\n"
        "====\n"
    ) % (name, recs)
    cfg = "SPECIFICATION Spec\nINVARIANTS\n    Conforms\n    ObsOK\n"
    with open("mc_%s.tla" % name, "w") as f:
        f.write(tla)
    with open("mc_%s.cfg" % name, "w") as f:
        f.write(cfg)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: parse_log.py <log-file> <name>")
    with open(sys.argv[1]) as f:
        emit(sys.argv[2], parse(f.readlines()))
