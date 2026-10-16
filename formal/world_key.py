"""What a TLC run of activation.tla reads in its world, for check.sh's memo
("Remembered runs" in README.md). A run's verdict is a function of the
definitions its states can evaluate, so its key holds only those: the
hand-written modules (the spec's directory) whole, and of each printed
module (a library directory) the text outside its definitions and every
definition reached from the config, from the whole modules and from that
text, except the actions the world cannot take. An action a world cannot
take is one whose needs (activation_footprints.tsv, printed beside the
tables that define it, a mutant's beside its own) the world's constants
(activation_worlds.tsv) do not give: the printer computes a need from the
guard it prints, so the action is false in every state of that world, and
a formula over it reads the same whatever its text. A change to such an
action reruns only the worlds that can take it. The text a world cannot
reach still parses in every verify, in the proofs, which extend the whole
model.

A module is the first file of its name in the spec's directory, then each
library directory in turn, as TLC finds it. A run whose world is not
printed, or a printed module whose definitions are not each a column-0 head
with an indented body, has no key here: check.sh keys it by every byte it
reads.

usage: world_key.py --spec <activation.tla> --out <dir>      < runs
       world_key.py --spec <activation.tla> --self-test [--plant cut|whole]
                                                               < runs

runs: one line per check, its config and its library (colon-separated),
tab-separated. --out writes each run's key lines to <dir>/<config name>.
--self-test changes one action a world can take and another cannot, as
printed, and holds the keys to it: every run that can take it changes key
and none other does. --plant checks the self-test with a mistake in the
key, and must fail: cut drops the changed action in every world, whole
keeps every printed module whole.
"""
import argparse
import hashlib
import os
import re
import sys

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
HEAD = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(\([^)]*\))?\s*==")
NAMES = re.compile(r"\b(?:EXTENDS|INSTANCE)\s+([A-Za-z0-9_]+(?:\s*,\s*[A-Za-z0-9_]+)*)")


class Unkeyed(Exception):
    """A run this script cannot key; check.sh keys it by every byte."""


def code(text):
    """The text with comments and strings blanked, so what is left names
    only what the module refers to. Block comments nest."""
    out, i, depth, n = [], 0, 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if depth:
            if two == "(*":
                depth, i = depth + 1, i + 2
            elif two == "*)":
                depth, i = depth - 1, i + 2
            else:
                i += 1
            continue
        if two == "(*":
            depth, i = 1, i + 2
        elif two == "\\*":
            while i < n and text[i] != "\n":
                i += 1
        elif text[i] == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            out.append('""')
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def idents(text):
    return set(IDENT.findall(code(text)))


def chunks(text):
    """The module as (name or None, text) chunks: a chunk starts at every
    line that starts at column 0, and is a definition when that line is a
    head. A top-level definition indented inside another's chunk would be
    cut with it, so a printed module with one has no key."""
    out, cur = [], []
    for line in text.splitlines(keepends=True):
        if line[:1] not in ("", " ", "\t", "\n", "\r") and cur:
            out.append(cur)
            cur = []
        cur.append(line)
    if cur:
        out.append(cur)
    named = []
    for lines in out:
        m = HEAD.match(lines[0])
        body = "".join(lines[1:])
        if m and any(HEAD.match(l.lstrip()) for l in code(body).splitlines()
                     if l[:1] in (" ", "\t")):
            raise Unkeyed("an indented definition in %s" % m.group(1))
        named.append((m.group(1) if m else None, "".join(lines)))
    return named


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def tsv(path):
    try:
        with open(path) as f:
            return [l.rstrip("\n").split("\t") for l in f
                    if l.strip() and not l.startswith("#")]
    except FileNotFoundError:
        return None


class Keys:
    def __init__(self, spec, overlay=None, plant=None):
        self.spec = os.path.abspath(spec)
        self.overlay = overlay or {}
        self.plant = plant
        self.texts, self.memo = {}, {}

    def once(self, what, arg, make):
        """make(arg), computed once a run of this script."""
        if (what, arg) not in self.memo:
            try:
                self.memo[(what, arg)] = make(arg)
            except Unkeyed as e:
                self.memo[(what, arg)] = e
        got = self.memo[(what, arg)]
        if isinstance(got, Unkeyed):
            raise got
        return got

    def read(self, path):
        if path not in self.texts:
            if path in self.overlay:
                self.texts[path] = self.overlay[path]
            else:
                with open(path) as f:
                    self.texts[path] = f.read()
        return self.texts[path]

    def modules(self, dirs):
        """Each module the spec reads, as (directory's place, name, path),
        the first file of its name in the directories."""
        todo, seen, out = [os.path.basename(self.spec)[:-4]], set(), []
        while todo:
            name = todo.pop(0)
            if name in seen:
                continue
            seen.add(name)
            for i, d in enumerate(dirs):
                path = os.path.join(d, name + ".tla")
                if path in self.overlay or os.path.isfile(path):
                    out.append((i, name, path))
                    todo += self.once("names", path, lambda p: [
                        n.strip() for g in NAMES.findall(code(self.read(p)))
                        for n in g.split(",")])
                    break
        return out

    def needs(self, d):
        """Each action's needs as printed beside the tables in d."""
        return self.once("needs", d, self._needs)

    def _needs(self, d):
        rows = tsv(os.path.join(d, "activation_footprints.tsv"))
        out = {}
        for r in rows or ():
            if len(r) >= 8 and r[7].strip():
                out[r[0]] = {(c.lstrip("~"), not c.startswith("~"))
                             for c in r[7].split()}
        return out

    def key(self, cfg, library, worlds, cut_also=frozenset()):
        """The key lines of a run of the spec under cfg, or Unkeyed."""
        name = os.path.basename(cfg)[:-4]
        if name not in worlds:
            raise Unkeyed("%s is no printed world" % name)
        consts = worlds[name]
        dirs = [os.path.dirname(self.spec)] + [os.path.abspath(d) for d in library]
        mods = self.modules(dirs)
        defs, parts, roots = {}, [], set(idents(self.read(cfg)))
        cut = set(cut_also)
        for i, mod, path in mods:
            if i == 0 or self.plant == "whole":
                roots |= self.once("idents", path, lambda p: idents(self.read(p)))
                parts.append((i, mod, path, None))
                continue
            needs = self.needs(os.path.dirname(path))
            pieces = self.once("chunks", path, lambda p: [
                (d, t, idents(t)) for d, t in chunks(self.read(p))])
            parts.append((i, mod, path, pieces))
            for d, text, ids in pieces:
                if d is None:
                    roots |= ids
                    continue
                if d in defs:
                    raise Unkeyed("%s is defined twice" % d)
                defs[d] = ids
                if any((c in consts) != want for c, want in needs.get(d, ())):
                    cut.add(d)
        reached, todo = set(), [r for r in roots if r in defs]
        while todo:
            d = todo.pop()
            if d in reached or d in cut:
                continue
            reached.add(d)
            todo += [r for r in defs[d] if r in defs]
        lines = ["world %s" % " ".join(sorted(consts)),
                 "cut %s" % " ".join(sorted(cut & set(defs)))]
        for i, mod, path, pieces in parts:
            if pieces is None:
                lines.append("%d/%s.tla whole %s" % (i, mod, sha(self.read(path))))
            else:
                kept = "".join(t for d, t, _ in pieces if d is None or d in reached)
                lines.append("%d/%s.tla part %s" % (i, mod, sha(kept)))
        return lines


def worlds_of(library):
    """Each printed config's constants, from the first library directory
    that prints them."""
    for d in library:
        rows = tsv(os.path.join(d, "activation_worlds.tsv"))
        if rows is not None:
            return {r[0]: set(r[1].split()) if len(r) > 1 else set() for r in rows}
    return {}


def runs():
    out = []
    for line in sys.stdin:
        if line.strip():
            cfg, library = line.rstrip("\n").split("\t")
            out.append((os.path.abspath(cfg), [d for d in library.split(":") if d]))
    return out


def keys(k, rs, cut_also=frozenset()):
    out = {}
    for cfg, library in rs:
        try:
            out[cfg] = k.key(cfg, library, worlds_of(library), cut_also)
        except Unkeyed:
            out[cfg] = None
    return out


def self_test(spec, rs, plant):
    """Change one printed action some world cannot take and see which keys
    move: every run that loads it and can take it, and no other."""
    base = Keys(spec)
    before = keys(base, rs)
    keyed = [(c, l) for c, l in rs if before[c] is not None]
    if not keyed:
        sys.exit("world key: no run has a world key")
    model = os.path.abspath(keyed[0][1][-1])
    tables = os.path.join(model, "activation_tables.tla")
    needs = base.needs(model)
    worlds = worlds_of([model])
    names = {d for d, _ in chunks(base.read(tables)) if d}
    def takes(world, action):
        return all((c in world) == want for c, want in needs.get(action, ()))
    action = next((a for a in sorted(needs) if a in names
                   and any(takes(w, a) for w in worlds.values())
                   and not all(takes(w, a) for w in worlds.values())), None)
    if action is None:
        sys.exit("world key: no printed action some world cannot take")
    text = base.read(tables)
    head = re.search(r"^%s\b[^\n]*==[^\n]*\n" % action, text, re.M)
    changed = text[:head.end()] + "    /\\ TRUE\n" + text[head.end():]
    after = keys(Keys(spec, overlay={tables: changed},
                      plant=plant if plant == "whole" else None),
                 rs, cut_also={action} if plant == "cut" else frozenset())
    wrong, moved = [], 0
    for cfg, library in keyed:
        loads = any(p == tables for _, _, p in
                    base.modules([os.path.dirname(base.spec)] + library))
        should = loads and takes(worlds_of(library).get(
            os.path.basename(cfg)[:-4], set()), action)
        did = before[cfg] != after[cfg]
        moved += did
        if did != should:
            wrong.append((cfg, should))
    for cfg, should in wrong:
        print("FAIL: a change to %s %s the key of %s" % (
            action, "leaves" if should else "changes", os.path.basename(cfg)))
    if wrong:
        sys.exit(1)
    print("OK   world key: a change to %s reruns %d of %d keyed runs, the"
          " ones that can take it; %d of %d runs are keyed"
          % (action, moved, len(keyed), len(keyed), len(rs)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--plant", choices=["cut", "whole"])
    args = ap.parse_args()
    rs = runs()
    if args.self_test:
        self_test(args.spec, rs, args.plant)
        return
    os.makedirs(args.out, exist_ok=True)
    for cfg, lines in keys(Keys(args.spec), rs).items():
        if lines is not None:
            with open(os.path.join(args.out, os.path.basename(cfg)[:-4]), "w") as f:
                f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
