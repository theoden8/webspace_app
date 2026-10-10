#!/usr/bin/env python3
"""Hold the Dart walks' steps against their TLA+ modules' state graphs.

Reads every <dir>/<module>.json that test/helpers/walk/model_trace.dart
wrote, has TLC dump the module's reachable graph (-dump dot,actionlabels)
under the trace's .cfg, projects each state onto the variables the walk
observes, and checks both directions:

  conformance  each step's states are reachable states of the model, and
               some path between them matches the step's action pattern;
  coverage     each projected transition (state, action, state) is taken by a
               step whose pattern can be that action alone, unless the action
               is listed for the module in walk_uncovered.tsv with its reason.
               A listed action that is fully covered fails too, so the list
               only shrinks.

usage: check_walk.py <trace-dir> --jar <tla2tools.jar>
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FORMAL = os.path.dirname(HERE)
UNCOVERED = os.path.join(HERE, "walk_uncovered.tsv")


# ── TLA+ values, as TLC prints them and as the walk writes them ──────────────

class _Parser:
    TOKEN = re.compile(r'\s*(<<|>>|\|->|"(?:[^"\\]|\\.)*"|-?\d+|[A-Za-z_]\w*|[{}\[\],])')

    def __init__(self, text):
        self.tokens = []
        pos = 0
        text = text.strip()
        while pos < len(text):
            m = self.TOKEN.match(text, pos)
            if not m:
                raise ValueError("cannot read TLA+ value %r at %d" % (text, pos))
            self.tokens.append(m.group(1))
            pos = m.end()
        self.at = 0

    def peek(self):
        return self.tokens[self.at] if self.at < len(self.tokens) else None

    def take(self, expected=None):
        tok = self.peek()
        if tok is None or (expected is not None and tok != expected):
            raise ValueError("expected %r, got %r" % (expected, tok))
        self.at += 1
        return tok

    def items(self, close):
        out = []
        if self.peek() == close:
            self.take(close)
            return out
        while True:
            out.append(self.value())
            if self.peek() == ",":
                self.take(",")
                continue
            self.take(close)
            return out

    def value(self):
        tok = self.take()
        if tok == "{":
            return ("set", frozenset(self.items("}")))
        if tok == "<<":
            return ("seq", tuple(self.items(">>")))
        if tok == "[":
            fields = []
            while True:
                name = self.take()
                self.take("|->")
                fields.append((name, self.value()))
                if self.peek() == ",":
                    self.take(",")
                    continue
                self.take("]")
                return ("rec", frozenset(fields))
        if tok in ("TRUE", "FALSE"):
            return ("bool", tok == "TRUE")
        if tok.startswith('"'):
            return ("str", json.loads(tok))
        if re.fullmatch(r"-?\d+", tok):
            return ("int", int(tok))
        return ("name", tok)


def tla_value(text):
    p = _Parser(text)
    v = p.value()
    if p.peek() is not None:
        raise ValueError("trailing input in TLA+ value %r" % text)
    return v


def show(state):
    return "{%s}" % ", ".join("%s=%s" % (k, _show(v)) for k, v in state)


def _show(v):
    kind, x = v
    if kind == "set":
        return "{%s}" % ", ".join(sorted(_show(e) for e in x))
    if kind == "seq":
        return "<<%s>>" % ", ".join(_show(e) for e in x)
    if kind == "bool":
        return "TRUE" if x else "FALSE"
    if kind == "str":
        return json.dumps(x)
    return str(x)


# ── TLC's graph, projected ───────────────────────────────────────────────────

_NODE = re.compile(r'^(-?\d+) \[label="((?:[^"\\]|\\.)*)"')
_EDGE = re.compile(r'^(-?\d+) -> (-?\d+) \[label="((?:[^"\\]|\\.)*)"')
_ESC = re.compile(r"\\(.)")


def _unescape(s):
    return _ESC.sub(lambda m: "\n" if m.group(1) == "n" else m.group(1), s)


def _state_of(label):
    variables = {}
    name = None
    for line in label.split("\n"):
        m = re.match(r"/\\ (\w+) = (.*)$", line)
        if m:
            name = m.group(1)
            variables[name] = m.group(2)
        elif name is not None:
            variables[name] += " " + line
    return {k: tla_value(v) for k, v in variables.items()}


def model_graph(module, config, jar, observed):
    """Reachable projected states and labelled projected transitions."""
    with tempfile.TemporaryDirectory() as tmp:
        dot = os.path.join(tmp, "graph.dot")
        run = subprocess.run(
            ["java", "-cp", jar, "tlc2.TLC", "-metadir", os.path.join(tmp, "states"),
             "-dump", "dot,actionlabels", dot, "-config", config, module + ".tla"],
            cwd=FORMAL, capture_output=True, text=True)
        if "Model checking completed. No error has been found." not in run.stdout:
            sys.exit("TLC did not check %s under %s cleanly:\n%s"
                     % (module, config, run.stdout[-3000:] + run.stderr[-2000:]))
        with open(dot) as f:
            lines = f.read().splitlines()
    states, edges = {}, set()
    for line in lines:
        m = _EDGE.match(line)
        if m:
            edges.add((m.group(1), _unescape(m.group(3)), m.group(2)))
            continue
        m = _NODE.match(line)
        if m:
            full = _state_of(_unescape(m.group(2)))
            missing = [v for v in observed if v not in full]
            if missing:
                sys.exit("%s has no variable %s" % (module, ", ".join(missing)))
            states[m.group(1)] = tuple((v, full[v]) for v in observed)
    projected = {(states[a], label, states[b]) for a, label, b in edges}
    return set(states.values()), projected


# ── action patterns ──────────────────────────────────────────────────────────

def pattern(text):
    tokens = []
    for tok in text.split():
        m = re.fullmatch(r"(\w+)([*?]?)", tok)
        if not m:
            raise ValueError("bad action pattern %r" % text)
        tokens.append((m.group(1), m.group(2)))
    return tokens


def path_exists(adjacency, tokens, start, goal):
    seen, todo = set(), [(start, 0)]
    while todo:
        node, k = todo.pop()
        if (node, k) in seen:
            continue
        seen.add((node, k))
        if k == len(tokens):
            if node == goal:
                return True
            continue
        name, kind = tokens[k]
        if kind in "*?":
            todo.append((node, k + 1))
        for label, nxt in adjacency.get(node, ()):
            if label == name:
                todo.append((nxt, k if kind == "*" else k + 1))
    return False


def accepts_single(tokens, label):
    """Whether the pattern matches the one-action path [label]."""
    def rest_empty(k):
        return all(kind in "*?" for _, kind in tokens[k:])
    for k, (name, kind) in enumerate(tokens):
        if name == label and rest_empty(k + 1):
            return True
        if kind not in "*?":
            return False
    return False


# ── the check ────────────────────────────────────────────────────────────────

def uncovered_list():
    listed = {}
    with open(UNCOVERED) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3 or not parts[2].strip():
                sys.exit("%s:%d: want module<TAB>action<TAB>reason" % (UNCOVERED, n))
            listed[(parts[0], parts[1])] = parts[2]
    return listed


def check(trace, jar, listed):
    module, config, steps = trace["module"], trace["config"], trace["steps"]
    if not steps:
        return ["%s: the walk recorded no steps" % module]
    observed = sorted(steps[0]["from"])
    for s in steps:
        if sorted(s["from"]) != observed or sorted(s["to"]) != observed:
            return ["%s: steps observe different variables" % module]
    reachable, transitions = model_graph(module, config, jar, observed)
    adjacency = {}
    for a, label, b in transitions:
        adjacency.setdefault(a, []).append((label, b))

    def state(raw):
        return tuple((v, tla_value(raw[v])) for v in observed)

    failures = []
    taken = []
    for s in steps:
        a, b, tokens = state(s["from"]), state(s["to"]), pattern(s["path"])
        for end in (a, b):
            if end not in reachable:
                failures.append("%s: the code reached %s, which the model cannot"
                                % (module, show(end)))
        if a in reachable and b in reachable and not (
                (not tokens and a == b) or (tokens and path_exists(adjacency, tokens, a, b))):
            failures.append("%s: no path matching %r leads from %s to %s"
                            % (module, s["path"], show(a), show(b)))
        taken.append((a, tokens, b))

    by_label = {}
    for a, label, b in transitions:
        by_label.setdefault(label, set()).add((a, b))
    print("  %s under %s: %d steps, %d reachable states, %d transitions"
          % (module, config, len(steps), len(reachable), len(transitions)))
    for label in sorted(by_label):
        pairs = by_label[label]
        missed = {(a, b) for a, b in pairs
                  if not any(a == x and b == y and accepts_single(t, label)
                             for x, t, y in taken)}
        reason = listed.get((module, label))
        if reason and not missed:
            failures.append("%s: %s is listed as uncovered but every transition is "
                            "taken; drop it from walk_uncovered.tsv" % (module, label))
        elif reason:
            print("    %-18s %d/%d taken; uncovered on purpose: %s"
                  % (label, len(pairs) - len(missed), len(pairs), reason))
        elif missed:
            sample = sorted(missed, key=str)[:3]
            failures.append("%s: %d/%d %s transitions are taken by no step, e.g. %s"
                            % (module, len(missed), len(pairs), label,
                               "; ".join("%s -> %s" % (show(a), show(b)) for a, b in sample)))
        else:
            print("    %-18s %d/%d taken" % (label, len(pairs), len(pairs)))
    for (m, label) in listed:
        if m == module and label not in by_label:
            failures.append("%s: walk_uncovered.tsv lists %s, which the model has no "
                            "transition for" % (module, label))
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--jar", required=True)
    args = ap.parse_args()
    files = sorted(f for f in os.listdir(args.dir) if f.endswith(".json")) \
        if os.path.isdir(args.dir) else []
    if not files:
        sys.exit("no walk traces in %s; did the Dart walks run with MODEL_WALK_DIR?"
                 % args.dir)
    listed = uncovered_list()
    failures = []
    for name in files:
        with open(os.path.join(args.dir, name)) as f:
            failures += check(json.load(f), os.path.abspath(args.jar), listed)
    for line in failures:
        print("FAIL " + line)
    if failures:
        sys.exit(1)
    print("Every walk step is a path the models allow, and every transition is taken "
          "or listed.")


if __name__ == "__main__":
    main()
