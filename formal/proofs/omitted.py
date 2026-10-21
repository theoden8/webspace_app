"""Holds every lemma a proof module states with PROOF OMITTED to one another
module of the same run proves: the same name, stated in the same words. A
printed steps module restates the lemmas it cites instead of extending the
modules that prove them, which tlapm takes as given either way; this is what
makes the restatement no weaker than the extension.

usage: omitted.py <module.tla>...
"""
import re
import sys

LEMMA = re.compile(r"^(?:LEMMA|THEOREM|PROPOSITION|COROLLARY) (\w+) ==$")
PROOF = re.compile(r"^\s*(?:BY\b|PROOF\b|OBVIOUS\b|<\d+>)")


def lemmas(path):
    """Each lemma of the module at [path]: its name, its statement and
    whether its proof is omitted."""
    lines = open(path, encoding="utf-8").read().splitlines()
    found = []
    for i, line in enumerate(lines):
        m = LEMMA.match(line)
        if not m:
            continue
        j = i + 1
        while j < len(lines) and not PROOF.match(lines[j]):
            j += 1
        statement = "\n".join(lines[i:j]).rstrip()
        omitted = j < len(lines) and lines[j].strip() == "PROOF OMITTED"
        found.append((m.group(1), statement, omitted))
    return found


def main(paths):
    proved = {}
    owed = []
    for path in paths:
        for name, statement, omitted in lemmas(path):
            if omitted:
                owed.append((path, name, statement))
            else:
                proved.setdefault(name, set()).add((path, statement))
    bad = []
    for path, name, statement in owed:
        twins = [p for p, s in proved.get(name, ()) if s == statement and p != path]
        if not twins:
            seen = proved.get(name)
            why = ("stated otherwise where it is proved" if seen
                   else "proved in no module of the run")
            bad.append(f"  FAIL: {path}: {name} is omitted and {why}")
    if bad:
        print("\n".join(bad))
        return 1
    print(f"  OK: {len(owed)} omitted lemmas, each proved word for word elsewhere")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
