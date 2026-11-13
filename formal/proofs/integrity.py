"""Holds the TLAPS proofs to what they rest on. tlapm proves an obligation
from what the module gives it, and a module can give it anything: an
assumption, a theorem with no proof, a step left bare, a lemma of a module
it extends, which tlapm takes as proved. Counting obligations sees none of
these, so this reads the modules and fails on each.

- assume: every top-level ASSUME, ASSUMPTION or AXIOM of a module the
  proofs reach is a row of assumptions.tsv (its module, its name and a
  digest of what it states), and every row is still stated somewhere, so
  the list only shrinks.
- unproved: a THEOREM, LEMMA, PROPOSITION or COROLLARY with PROOF OMITTED
  or no proof at all holds only where another module of the run proves it
  under the same name in the same words. A printed steps module restates
  the lemmas it cites so instead of extending the modules that prove them.
- holes: inside a proof, a step left with no proof (a bare QED), as the
  proving run's own output reports it (tlapm #271: under `--strict`,
  `Missing proof at` and `Omitted proof at` each locus); an omitted proof
  there is one the previous rule admits, and no other. A run that reports
  no omitted proof for a module stating some (one without `--strict`) is
  refused, so the rule cannot pass for want of the report.
- reach: a theorem of a module a proof EXTENDS or INSTANCEs that the run
  does not prove itself is taken as given by tlapm, so it fails unless a
  module of the run proves it word for word.

Rung 5: TLA+ has no type for "proved", and tlapm reports a theorem it was
given as readily as one it proved. The rules follow TLAPS-Bench's soundness
checks (specula-org/TLAPS-Bench, src/tlacheck/rules), written again over
our layout. `--plant` makes each mistake in a module of its own and fails
unless every rule catches its own.

usage: integrity.py --allow assumptions.tsv [--search DIR]...
                    [--outputs DIR] <module.tla>...
       integrity.py --plant
The outputs are each module's proving run, <module>.out, as
check_proofs.sh keeps them.
"""
import argparse
import hashlib
import os
import re
import sys
import tempfile

# Run with -I, which leaves the script's own directory off the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tla_text  # noqa: E402

STATEMENT = re.compile(
    r"^(THEOREM|LEMMA|PROPOSITION|COROLLARY)\b\s*(?:(\w+)\s*==)?")
ASSUMPTION = re.compile(r"^(ASSUME|ASSUMPTION|AXIOM)\b\s*(?:(\w+)\s*==)?")
PROOF = re.compile(r"^\s*(?:PROOF\b|BY\b|OBVIOUS\b|OMITTED\b|<\d+>)")
OMITTED = re.compile(r"^\s*(?:PROOF\s+)?OMITTED\s*$")
EXTENDS = re.compile(r"^\s*(?:LOCAL\s+)?EXTENDS\b(.*)$")
INSTANCE = re.compile(r"\bINSTANCE\s+(\w+)")
# What a proving run prints for each step it was given no proof of
# (src/tlapm_lib.ml), and the lines that say the module was read at all.
HOLE = re.compile(r'(Missing|Omitted) proof at File "[^"]*", line (\d+)')
READ = re.compile(r"obligations? proved|Proof incomplete in module")


def code(text):
    """[text] with its comments blanked, line breaks kept, so line numbers
    stay tlapm's."""
    return tla_text.code(text, keep_strings=True)


def words(text):
    return re.sub(r"\s+", " ", text).strip()


class Module:
    """A module's units as the rules read them: its theorems, whether each
    is proved and in what words, its assumptions, and what it extends."""

    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)[:-len(".tla")]
        lines = code(open(path, encoding="utf-8").read()).splitlines()
        self.theorems = []
        self.assumptions = []
        self.extends = set()
        for i, line in enumerate(lines):
            if m := EXTENDS.match(line):
                self.extends |= {w for w in re.findall(r"\w+", m.group(1))}
            self.extends |= set(INSTANCE.findall(line))
            if m := STATEMENT.match(line):
                body, proof = self._unit(lines, i)
                self.theorems.append({
                    "line": i + 1,
                    "name": m.group(2),
                    "words": words(body),
                    "proof": proof,
                    "proof_line": i + 1 + body.count("\n") + 1,
                })
            elif m := ASSUMPTION.match(line):
                body, _ = self._unit(lines, i)
                self.assumptions.append({
                    "line": i + 1,
                    "name": m.group(2) or "",
                    "digest": hashlib.sha256(
                        words(body).encode()).hexdigest()[:16],
                })

    @staticmethod
    def _unit(lines, i):
        """The text of the unit starting at line [i] up to its proof, and
        how it is proved: "proof", "omitted", or "none" when the next unit
        starts first."""
        body = [lines[i]]
        for line in lines[i + 1:]:
            if PROOF.match(line):
                return "\n".join(body), (
                    "omitted" if OMITTED.match(line) else "proof")
            if line[:1].strip():
                break
            body.append(line)
        return "\n".join(body), "none"


def closure(modules, search):
    """Every module the run's [modules] reach through EXTENDS and INSTANCE
    that a directory of [search] holds, by name; tlapm's own library is
    found nowhere here and is not read."""
    found = {m.name: m for m in modules}
    todo = list(modules)
    while todo:
        for name in todo.pop().extends:
            if name in found:
                continue
            for d in search:
                p = os.path.join(d, name + ".tla")
                if os.path.isfile(p):
                    found[name] = Module(p)
                    todo.append(found[name])
                    break
    return found


def proved_words(run):
    """Each statement a module of the run proves, by its name or, unnamed,
    by its words: (name, words) -> the modules that prove it."""
    proved = {}
    for m in run:
        for t in m.theorems:
            if t["proof"] == "proof":
                proved.setdefault((t["name"], t["words"]), set()).add(m.name)
    return proved


def check(run, *, allow, search, outputs, ran=None):
    fails = []
    reached = closure(run, search)
    names = {m.name for m in run}
    proved = proved_words(run)

    def twin(m, t):
        return any(p != m.name for p in proved.get((t["name"], t["words"]), ()))

    # assume
    stated = set()
    for m in reached.values():
        for a in m.assumptions:
            row = (m.name, a["name"], a["digest"])
            stated.add(row)
            if row not in allow:
                fails.append(
                    f"assume: {m.path}:{a['line']}: {a['name'] or 'an unnamed assumption'}"
                    f" is assumed and not listed in assumptions.tsv"
                    f" (\t{m.name}\t{a['name']}\t{a['digest']})")
    for row in sorted(set(allow) - stated):
        fails.append(f"assume: {row[0]}'s {row[1] or 'unnamed'} assumption "
                     f"({row[2]}) is no longer stated: drop its row")

    # unproved, and the omitted lines holes may admit
    admitted = {}
    for m in run:
        for t in m.theorems:
            if t["proof"] == "proof":
                continue
            if twin(m, t):
                if t["proof"] == "omitted":
                    admitted.setdefault(m.name, set()).add(t["proof_line"])
                continue
            label = t["name"] or f"the theorem at line {t['line']}"
            how = "is omitted" if t["proof"] == "omitted" else "has no proof"
            elsewhere = t["name"] and any(
                n == t["name"] for n, _ in proved)
            why = ("stated otherwise where it is proved" if elsewhere
                   else "proved in no module of the run")
            fails.append(f"unproved: {m.path}:{t['line']}: {label} {how} and {why}")

    # reach
    for m in reached.values():
        if m.name in names:
            continue
        for t in m.theorems:
            if not twin(m, t):
                label = t["name"] or f"the theorem at line {t['line']}"
                fails.append(
                    f"reach: {m.path}:{t['line']}: {label} is taken as given by "
                    "the proofs that extend it, and the run proves it nowhere")

    # holes
    if outputs is not None:
        # A proof shard reads the runs of its own modules (`ran`);
        # proof_shards.py's merge holds every module to one shard.
        for m in run:
            if ran is not None and m.name not in ran:
                continue
            p = os.path.join(outputs, m.name + ".out")
            out = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
            if not READ.search(out):
                fails.append(f"holes: {m.path}: no proving run of it was read")
                continue
            holes = HOLE.findall(out)
            for kind, line in holes:
                if kind == "Missing":
                    fails.append(f"holes: {m.path}:{line}: a step with no proof")
                elif int(line) not in admitted.get(m.name, ()):
                    fails.append(f"holes: {m.path}:{line}: an omitted proof no "
                                 "other module of the run proves")
            stated = sum(t["proof"] == "omitted" for t in m.theorems)
            if stated and not any(k == "Omitted" for k, _ in holes):
                fails.append(f"holes: {m.path} states {stated} omitted proofs "
                             "and its run reports none: tlapm reports holes "
                             "only under --strict (tlapm #271)")
    return fails


def read_allow(path):
    rows = set()
    for line in open(path, encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.rstrip("\n").split("\t")
        rows.add((cols[0], cols[1], cols[2]))
    return rows


# The planted mistakes, each the shape of one a proof has made or could:
# the module that must fail by it, and the rule that must name it.
CLEAN = {
    "Spec.tla": """---- MODULE Spec ----
EXTENDS Naturals
CONSTANT N
ASSUME NType == N \\in Nat
VARIABLE x
Init == x = 0
====
""",
    "Lemmas.tla": """---- MODULE Lemmas ----
EXTENDS Spec, TLAPS
LEMMA Zero == 0 \\in Nat
  BY DEF Init
====
""",
    "Uses.tla": """---- MODULE Uses ----
EXTENDS Spec, TLAPS
LEMMA Zero == 0 \\in Nat
PROOF OMITTED
THEOREM T == Init => x \\in Nat
<1>1. 0 \\in Nat
  BY Zero
<1> QED
  BY <1>1 DEF Init
====
""",
}
PLANTS = {
    "assume": ("Spec.tla", "ASSUME NType == N \\in Nat\n",
               "ASSUME NType == N \\in Nat\nAXIOM Supports == N > 0\n"),
    "unproved": ("Uses.tla", "LEMMA Zero == 0 \\in Nat\nPROOF OMITTED\n",
                 "LEMMA Zero == 0 \\in Nat /\\ 1 \\in Nat\nPROOF OMITTED\n"),
    "unproved-bare": ("Uses.tla", "  BY <1>1 DEF Init\n====\n",
                      "  BY <1>1 DEF Init\nLEMMA Bare == N > 0\n====\n"),
    "holes": ("Uses.tla", "<1> QED\n  BY <1>1 DEF Init\n", "<1> QED\n"),
    "reach": ("Spec.tla", "Init == x = 0\n",
              "Init == x = 0\nTHEOREM Given == N > 0\n  BY NType\n"),
}
ALLOW = {("Spec", "NType",
          hashlib.sha256(words("ASSUME NType == N \\in Nat").encode())
          .hexdigest()[:16])}


def proving_output(d, name):
    """What `tlapm --strict` prints proving [name] in [d], as 1.6.0-pre
    does: a line for each missing proof (a bare QED) or omitted one (PROOF
    OMITTED), the module's incomplete line, then its count, which it prints
    whether or not the proof is complete."""
    lines = open(os.path.join(d, f"{name}.tla"), encoding="utf-8").read().splitlines()
    path = os.path.join(d, f"{name}.tla")
    out, holes = [], 0
    for i, line in enumerate(lines):
        bare = line == "<1> QED" and not (
            i + 1 < len(lines) and lines[i + 1].startswith("  BY"))
        if bare or OMITTED.match(line):
            kind = "Missing" if bare else "Omitted"
            out.append(f'{kind} proof at File "{path}", line {i + 1}, '
                       f'characters 1-{len(line)}')
            holes += 1
        elif STATEMENT.match(line) and not any(
                PROOF.match(n) for n in lines[i + 1:i + 2]) and (
                i + 1 == len(lines) or lines[i + 1][:1].strip()):
            out.append(f'Missing proof at File "{path}", line {i + 1}, '
                       f'characters 1-{len(line)}')
            holes += 1
    if holes:
        out.append(f'[ERROR]: Proof incomplete in module "{name}": {holes} '
                   "missing or omitted proof step(s).")
    out.append("[INFO]: All 2 obligations proved.")
    return "\n".join(out) + "\n"


def run_world(files, *, reported=True, ran=None, unread=()):
    with tempfile.TemporaryDirectory() as d:
        for name, text in files.items():
            open(os.path.join(d, name), "w", encoding="utf-8").write(text)
        outs = os.path.join(d, "outputs")
        os.mkdir(outs)
        run = [Module(os.path.join(d, n)) for n in ("Lemmas.tla", "Uses.tla")]
        for m in run:
            if m.name in unread:
                continue
            out = proving_output(d, m.name)
            if not reported:
                out = "[INFO]: All 2 obligations proved.\n"
            open(os.path.join(outs, m.name + ".out"), "w").write(out)
        return check(run, allow=ALLOW, search=[d], outputs=outs, ran=ran)


def plant():
    clean = run_world(CLEAN)
    if clean:
        print("\n".join(["  FAIL: the clean world fails:"] + clean))
        return 1
    bad = 0
    for mistake, (file, old, new) in PLANTS.items():
        files = dict(CLEAN)
        assert old in files[file], (mistake, old)
        files[file] = files[file].replace(old, new, 1)
        rule = mistake.split("-")[0]
        caught = [f for f in run_world(files)
                  if f.startswith(rule + ":")]
        if caught:
            print(f"  OK   planted {mistake}: {caught[0].split(': ', 1)[1]}")
        else:
            print(f"  FAIL planted {mistake}: no {rule} failure")
            bad = 1
    # A tlapm that reports no hole at all, which would leave the rule blind.
    blind = [f for f in run_world(CLEAN, reported=False) if f.startswith("holes:")]
    if blind:
        print(f"  OK   planted unreported holes: {blind[0].split(': ', 1)[1]}")
    else:
        print("  FAIL planted unreported holes: no holes failure")
        bad = 1
    # A shard reads only the runs it made: another shard's module is not
    # missed, and its own one with no run is.
    if run_world(CLEAN, ran={"Lemmas"}, unread={"Uses"}):
        print("  FAIL planted shard: a module another shard proved is missed")
        bad = 1
    own = [f for f in run_world(CLEAN, ran={"Uses"}, unread={"Uses"})
           if f.startswith("holes:")]
    if own:
        print(f"  OK   planted shard: {own[0].split(': ', 1)[1]}")
    else:
        print("  FAIL planted shard: a shard's own module with no run passes")
        bad = 1
    print(f"  {'FAIL' if bad else 'OK'}: every planted mistake caught")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--allow")
    ap.add_argument("--search", action="append", default=[])
    ap.add_argument("--outputs")
    ap.add_argument("--proved", help="comma-separated: the modules whose "
                    "runs --outputs holds, when they are not all of them")
    ap.add_argument("--plant", action="store_true")

    ap.add_argument("modules", nargs="*")
    a = ap.parse_args()
    if a.plant:
        return plant()
    run = [Module(p) for p in a.modules]
    search = a.search + sorted({os.path.dirname(os.path.abspath(p)) for p in a.modules})
    ran = set(filter(None, a.proved.split(","))) if a.proved is not None else None
    fails = check(run, allow=read_allow(a.allow), search=search,
                  outputs=a.outputs, ran=ran)
    if fails:
        print("\n".join("  FAIL " + f for f in fails))
        return 1
    held = sum(len(m.theorems) for m in run)
    omitted = sum(t["proof"] != "proof" for m in run for t in m.theorems)
    print(f"  OK: {held} statements in {len(run)} modules, {omitted} omitted "
          "and each of those proved word for word in another; every "
          "assumption listed"
          + ("; no hole in any proving run" if a.outputs else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
