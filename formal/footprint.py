"""Composition by footprint, held for activation.tla: two actions that share
a variable must both be taken in one world TLC checks, so their
interleavings are checked together. The pairs are the printer's
(activation_pairs.tsv, from the declarations), and this gate holds them to
the text: each action's footprint is read from its text (written: primed;
read: named unprimed, through the operators it calls), a table action's,
an environment action's and a base operator's must equal what their
declarations print, and the pairs the text shares must be the printer's. A
flow writes only its own row of fl, so two writes of fl are no meeting, and
a read of other flows' rows meets only the steps that can run in a row of a
kind it reads and write a field it reads. What each world takes is read
from TLC's coverage of its holding check, written or printed (the printer
makes a world for every pair no written world can take,
activation_printed_worlds.tsv), and a pair no world takes together must be
listed in footprint_debt.tsv, which only shrinks: a new pair fails, and so
does a listed pair a world now covers. A pair whose needs contradict runs
in no world and is no debt. What an action needs of the model's constants
(its needs column) is necessary: a world that takes it sets every
constant it needs set and none it needs left (activation_worlds.tsv).

usage: footprint.py --model <printed dir> --coverage <dir of TLC logs>
                    --debt <footprint_debt.tsv> [--write]

--write rewrites the debt list from this run instead of checking it.
--plant checks the list with one mistake planted and must fail: a pair no
world needs listed, when the list has one a listed pair left off, a read
dropped from a table action's declarations, an untaken action left off
untaken.tsv, the rows a table action reads dropped, or a need no world
that takes the action gives.
"""
import argparse
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# What the model keeps for the checkers, not for the flows: the step just
# taken, the input count that bounds a behavior, the witnesses met.
UNSHARED = {"last", "inputs", "seen"}
# The event loop every input waits on (Calm: every flow waits on a reply),
# which is how the model schedules, not state a flow owns; and where an
# input lands (Lands), which Did checks for the inputs alone.
SCHEDULER = {"Calm", "Idle", "Lands"}
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip(text):
    text = re.sub(r"\(\*.*?\*\)", " ", text, flags=re.S)
    text = re.sub(r"\\\*[^\n]*", " ", text)
    text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
    # A record's field names are not operators: `![f].site`, `[t |-> s]`.
    text = re.sub(r"\.[A-Za-z_]\w*", " ", text)
    return re.sub(r"[A-Za-z_]\w*\s*\|->", " ", text)


def modules(model):
    paths = [os.path.join(model, m) for m in
             ("activation_vars.tla", "activation_steps.tla",
              "activation_ops.tla", "activation_tables.tla")]
    paths += [os.path.join(HERE, m) for m in
              ("activation_base.tla", "activation.tla")]
    return {os.path.basename(p)[:-4]: open(p).read() for p in paths}


def definitions(sources):
    """Every operator's body, by name, from the modules' column-0 heads."""
    defs = {}
    head = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\([^)]*\))? ==", re.M)
    for text in sources.values():
        text = strip(text)
        marks = list(head.finditer(text))
        for i, m in enumerate(marks):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
            body = text[m.end():end].split("\n====")[0]
            defs[m.group(1)] = body
    return defs


def variables(sources):
    block = strip(sources["activation_vars"]).split("VARIABLES", 1)[1]
    block = block.split("NoFlow", 1)[0]
    return set(IDENT.findall(block)) - {"VARIABLES"}


def footprints(defs, vars_, inputs):
    """Read and written variables of each definition, through every operator
    it calls. A flow's own record (fl[f]) is its own; reading another
    flow's (fl[g], a set of them) is reading what every flow writes."""
    memo = {}

    def own(body):
        body = re.sub(r"UNCHANGED\s*(<<[^>]*>>|[A-Za-z_]\w*)", " ", body)
        written = {v for v in re.findall(r"([A-Za-z_]\w*)'", body)
                   if v in vars_}
        # A primed name is what the action writes, not what it reads.
        unprimed = re.sub(r"[A-Za-z_]\w*'", " ", body)
        read = {t for t in IDENT.findall(unprimed) if t in vars_} - {"fl"}
        bound = re.search(r"\\[AE]\s*f\s*\\in", body) is not None
        for m in re.finditer(r"\bfl\b", body):
            after = body[m.end():]
            own = re.match(r"'|\s*EXCEPT\b|\s*\[\s*f\s*\]", after)
            if not own or (bound and after.lstrip().startswith("[")):
                read.add("fl")
        calls = {t for t in IDENT.findall(body) if t in defs} - SCHEDULER
        return read, written, calls

    def walk(name, seen):
        if name in memo:
            return memo[name]
        if name in seen:
            return set(), set()
        read, written, calls = own(defs[name])
        for c in calls - {name}:
            r, w = walk(c, seen | {name})
            read |= r
            written |= w
        memo[name] = (read, written)
        return memo[name]

    prints = {name: walk(name, set()) for name in defs}
    lands = own(defs["Lands"])
    for name in inputs:
        read, written = prints[name]
        prints[name] = (read | lands[0], written | lands[1])
    return prints


def declared(model, prints, vars_, inputs):
    """Each table action's footprint as its declarations print it
    (activation_footprints.tsv): its own reads and writes, plus those of the
    base operators it names, read from their text as every action's are;
    and its rows: the kinds its own row can hold, the fields of it it
    writes, and the fields of other rows it reads, by kind."""
    out, rows = {}, {}
    lands = prints.get("Lands", (set(), set()))
    for line in open(os.path.join(model, "activation_footprints.tsv")):
        if not line.strip() or line.startswith("#"):
            continue
        cols = (line.rstrip("\n").split("\t") + [""] * 8)[:8]
        action, reads, writes, base, kinds, fields, others, needs = cols
        rows[action] = (set(kinds.split()), set(fields.split()),
                        {tuple(r.split(".")) for r in others.split()},
                        None if needs == "unreached" else
                        {(n.lstrip("~"), not n.startswith("~"))
                         for n in needs.split()})
        r = set(reads.split()) & vars_
        w = set(writes.split()) & vars_
        for op in base.split():
            if op not in prints:
                sys.exit("footprint: %s calls %s, which no module defines"
                         % (action, op))
            r |= prints[op][0]
            w |= prints[op][1]
        if action in inputs:
            r |= lands[0]
            w |= lands[1]
        out[action] = (r, w)
    return out, rows


def taken(log, sources):
    """The actions a world's holding check took at least once, by name; an
    action TLC names by its position is named by the text there."""
    out = set()
    pat = re.compile(r"^<(\w+) line (\d+), col (\d+) to line (\d+), col (\d+)"
                     r" of module (\w+)(?: \((\d+) (\d+) (\d+) (\d+)\))?>:"
                     r" \d+:(\d+)$", re.M)
    for m in pat.finditer(open(log).read()):
        name, module, total = m.group(1), m.group(6), int(m.group(11))
        if total == 0 or name in ("Init", "Done"):
            continue
        if m.group(7):
            l1, c1, l2, c2 = (int(m.group(i)) for i in range(7, 11))
            lines = sources[module].split("\n")[l1 - 1:l2]
            lines[-1] = lines[-1][:c2]
            lines[0] = lines[0][c1 - 1:]
            out.add("%s@%s" % (name, " ".join(" ".join(lines).split())))
        else:
            out.add(name)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--coverage", required=True)
    ap.add_argument("--debt", required=True)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--plant", choices=["listed", "unlisted", "declared",
                                        "untaken", "rows", "needs",
                                        "invariant"])
    ap.add_argument("--untaken", default=os.path.join(HERE, "untaken.tsv"))
    args = ap.parse_args()

    sources = modules(args.model)
    defs = definitions(sources)
    vars_ = variables(sources) - UNSHARED
    inputs = re.findall(r'"(\w+)"', re.search(
        r"^Inputs == \{([^}]*)\}", sources["activation_steps"], re.M).group(1))
    prints = footprints(defs, vars_, inputs)
    def print_of(action):
        """An action's footprint from its text; one TLC names by its
        position (`InputStep@<text>`) from the text there."""
        if "@" not in action:
            return prints[action]
        body = action.split("@", 1)[1]
        read, written = set(), set()
        for t in set(IDENT.findall(body)):
            if t in prints:
                r, w = prints[t]
                read |= r
                written |= w
            elif t in vars_:
                read.add(t)
        return read, written

    # Each base operator a table calls reads and writes what BaseOp says.
    wrong = []
    for line in open(os.path.join(args.model, "activation_base_ops.tsv")):
        if not line.strip() or line.startswith("#"):
            continue
        op, reads, writes = (line.rstrip("\n").split("\t") + [""] * 3)[:3]
        tr, tw = prints[op]
        if op == "Input":
            tr, tw = tr | prints["Lands"][0], tw | prints["Lands"][1]
        if (set(reads.split()), set(writes.split())) != (tr, tw):
            wrong.append(op)
            print("FAIL: BaseOp %s declares reads %s, writes %s; its text"
                  " reads %s, writes %s" % (op, sorted(reads.split()),
                  sorted(writes.split()), sorted(tr), sorted(tw)))
    if wrong:
        sys.exit(1)

    # Each invariant reads what `Inv` declares, and holds at rest only
    # where it says so (`Idle =>`).
    invariants = []
    for line in open(os.path.join(args.model, "activation_invariants.tsv")):
        if line.strip() and not line.startswith("#"):
            name, rest, reads = (line.rstrip("\n").split("\t") + [""])[:3]
            invariants.append((name, rest == "true", set(reads.split())))
    if args.plant == "invariant":
        name, rest, reads = invariants[0]
        invariants[0] = (name, rest, set(sorted(reads)[1:]))
    for name, rest, reads in invariants:
        tr = prints[name][0]
        idle = "Idle" in IDENT.findall(defs[name])
        if (reads, rest) != (tr, idle):
            wrong.append(name)
            print("FAIL: %s declares reads %s%s; its text reads %s%s"
                  % (name, sorted(reads), " at rest" if rest else "",
                     sorted(tr), " at rest" if idle else ""))
    if wrong:
        sys.exit(1)

    decl, rows = declared(args.model, prints, vars_, inputs)
    if args.plant == "rows":
        action = min(a for a in rows if rows[a][2])
        rows[action] = (rows[action][0], rows[action][1], set(),
                        rows[action][3])
    if args.plant == "declared":
        action = min(a for a in decl if decl[a][0])
        decl[action] = (set(sorted(decl[action][0])[1:]), decl[action][1])
    for action, (r, w) in sorted(decl.items()):
        tr, tw = print_of(action)
        if (r, w) != (tr, tw):
            wrong.append(action)
            print("FAIL: %s declares reads %s, writes %s; its text reads %s,"
                  " writes %s" % (action, sorted(r), sorted(w), sorted(tr),
                                  sorted(tw)))
    # Its text reads another flow's row exactly when it declares the rows.
    for action, (r, w) in sorted(decl.items()):
        if ("fl" in r) != bool(rows[action][2]):
            wrong.append(action)
            print("FAIL: %s's text %s fl, and it declares rows %s"
                  % (action, "reads" if "fl" in r else "does not read",
                     sorted(".".join(x) for x in rows[action][2])))
    if wrong:
        sys.exit(1)
    worlds = {}
    for log in sorted(glob.glob(os.path.join(args.coverage, "*.log"))):
        worlds[os.path.basename(log)[:-4]] = taken(log, sources)
    if not worlds:
        sys.exit("footprint: no coverage under %s" % args.coverage)

    # What an action needs, every world that takes it gives.
    sets = {}
    for line in open(os.path.join(args.model, "activation_worlds.tsv")):
        if line.strip() and not line.startswith("#"):
            cfg, _, consts = line.rstrip("\n").partition("\t")
            sets[cfg] = set(consts.split())
    if args.plant == "needs":
        planted = next(((a, c) for w in sorted(worlds) for a in sorted(worlds[w])
                        if a in rows and rows[a][3] is not None
                        for c in sorted(set().union(*sets.values()) - sets.get(w, set()))),
                       None)
        if planted:
            a, c = planted
            rows[a] = rows[a][:3] + (rows[a][3] | {(c, True)},)
    ungiven = False
    for w, took_here in sorted(worlds.items()):
        if w not in sets:
            sys.exit("footprint: %s has coverage but no constants in"
                     " activation_worlds.tsv" % w)
        for a in sorted(took_here):
            needs = rows.get(a, (None,) * 4)[3]
            for c, want in sorted(needs or ()):
                if (c in sets[w]) != want:
                    ungiven = True
                    print("FAIL: %s takes %s, which needs %s%s, and %s it"
                          % (w, a, "" if want else "~", c,
                             "leaves" if want else "sets"))
    if ungiven:
        sys.exit(1)

    # A table action no world takes is checked by nothing: it is taken in
    # some world, or listed with why no world can (untaken.tsv, which only
    # shrinks).
    took = set().union(*worlds.values())
    skipped = {l.split("\t")[0] for l in open(args.untaken)
               if l.strip() and not l.startswith("#")}
    if args.plant == "untaken":
        skipped.discard(min(skipped, default=None))
    vacuous = False
    for action in sorted(set(decl) - took - skipped):
        vacuous = True
        print("FAIL: no world takes %s, so nothing checks it: take it in a"
              " world or list it in %s with why none can"
              % (action, os.path.basename(args.untaken)))
    for action in sorted(skipped & took):
        vacuous = True
        print("FAIL: a world takes %s now: drop it from %s"
              % (action, os.path.basename(args.untaken)))
    for action in sorted(skipped - set(decl)):
        vacuous = True
        print("FAIL: %s, listed in %s, is no action of the tables"
              % (action, os.path.basename(args.untaken)))
    if vacuous:
        sys.exit(1)

    def rows_meet(reader, writer):
        """Whether [reader] reads a field of a row [writer] can write: by
        the declared rows where both are table actions, else whenever one
        reads fl and the other writes it."""
        if reader not in rows or writer not in rows:
            return "fl" in print_of(reader)[0] and "fl" in print_of(writer)[1]
        kinds, fields = rows[writer][:2]
        return any(k in kinds and (f in fields or "*" in fields)
                   for k, f in rows[reader][2])

    # Two actions whose needs contradict (one needs a constant set the
    # other needs left) run in no world, so they never interleave.
    apart = set()
    for line in open(os.path.join(args.model, "activation_printed_worlds.tsv")):
        if line.startswith("-\t"):
            _, a, b = line.rstrip("\n").split("\t")
            apart.add((a, b))

    # The pairs the printer computes from the declarations, among the
    # actions some world takes, are the ones the text shares.
    printed = {}
    for line in open(os.path.join(args.model, "activation_pairs.tsv")):
        if line.strip() and not line.startswith("#"):
            a, b, v = (line.rstrip("\n").split("\t") + [""])[:3]
            if a in took and b in took and (a, b) not in apart:
                printed[(a, b)] = sorted(v.split())
    actions = sorted(took)
    met = {}
    for i, a in enumerate(actions):
        ra, wa = print_of(a)
        for b in actions[i:]:
            rb, wb = print_of(b)
            # A flow writes only its own row of fl, so two writes of fl
            # meet only where one flow reads a field of the other's row.
            shared = ((wa & wb) | (wa & rb) | (wb & ra)) - {"fl"}
            if rows_meet(a, b) or rows_meet(b, a):
                shared.add("fl")
            if shared and (a, b) not in apart:
                met[(a, b)] = sorted(shared)
    if met != printed:
        for k in sorted(k for k in set(met) | set(printed)
                        if met.get(k) != printed.get(k)):
            print("FAIL: %s and %s: the text shares %s, the printer %s"
                  % (k[0], k[1], met.get(k), printed.get(k)))
        sys.exit(1)

    pairs = {k: v for k, v in printed.items()
             if not any(k[0] in t and k[1] in t for t in worlds.values())}
    rows = ["%s\t%s\t%s" % (a, b, " ".join(v)) for (a, b), v in sorted(pairs.items())]
    if args.write:
        with open(args.debt, "w") as f:
            f.write("# Two actions sharing a variable that no checked world takes\n"
                    "# together: action, action, the variables they share.\n"
                    "# Printed by formal/footprint.py --write; only shrinks.\n")
            f.write("".join(r + "\n" for r in rows))
        print("footprint: wrote %d pairs to %s" % (len(rows), args.debt))
        return
    listed = {tuple(l.split("\t")[:2]) for l in open(args.debt)
              if l.strip() and not l.startswith("#")}
    if args.plant == "listed":
        listed.add(("Planted", "Planted"))
    elif args.plant == "unlisted":
        if not listed:
            sys.exit(0)
        listed.discard(min(listed))
    new = sorted(set(pairs) - listed)
    gone = sorted(listed - set(pairs))
    for a, b in new:
        print("FAIL: %s and %s share %s, and no world takes both"
              % (a, b, ", ".join(pairs[(a, b)])))
    for a, b in gone:
        print("FAIL: %s and %s are now taken together or share nothing:"
              " drop them from %s" % (a, b, os.path.basename(args.debt)))
    if new or gone:
        sys.exit(1)
    print("OK   footprint: %d actions in %d worlds; %d pairs that share a"
          " variable are checked apart, as listed"
          % (len(actions), len(worlds), len(pairs)))


if __name__ == "__main__":
    main()
