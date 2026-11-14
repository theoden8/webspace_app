"""The key of what verify.sh --resume keeps.

A kept stage (the printed model, a schedule shard) is reused only while this
key is the one it was made under, so the key reads every input a stage could
read: each tracked or untracked, unignored file's path and bytes; every
environment variable under ENV_PREFIXES, which bound the schedules and the
walks, less the few in HOW that say only how the run is carried out; and the
toolchain's own account of its version. It reads more than any
one stage needs, which costs a rerun, never a stale result.

usage: input_key.py ROOT [--tool TEXT] [--plant PREFIX]
  --tool TEXT     what the toolchain says of itself (`flutter --version`)
  --plant PREFIX  leaves out the files and variables under PREFIX: a key that
                  misses an input, which the gate test must catch
"""
import argparse
import hashlib
import os
import subprocess
import sys

ENV_PREFIXES = ("SCHEDULE_", "WALK_", "FORMAL_")

# Variables under ENV_PREFIXES that say how a run is carried out, never what it
# checks, so a stop resumed under other values keeps what it made. A shard's
# stamp names the split it was cut for, so a split FORMAL_SLOTS changes is
# redone by that stamp, not by the key.
HOW = {
    "FORMAL_SLOTS": "cores the TLC pool and the schedule split use",
    "FORMAL_PARALLEL": "how many schedule shards run at once",
    "FORMAL_CACHE": "where the TLC and replay memos live",
    "FORMAL_PROGRESS_SECONDS": "how often a running check prints its progress",
}


def files(root):
    listed = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "-co", "--exclude-standard"],
        check=True, capture_output=True).stdout
    return sorted({p.decode() for p in listed.split(b"\0") if p})


def key(root, *, tool="", plant=None):
    digest = hashlib.sha256()
    digest.update(f"tool\0{len(tool)}\0{tool}".encode())
    for name in sorted(os.environ):
        if name in HOW:
            continue
        if name.startswith(ENV_PREFIXES) and not (plant and name.startswith(plant)):
            digest.update(f"env\0{name}\0{os.environ[name]}\0".encode())
    for name in files(root):
        if plant is not None and name.startswith(plant):
            continue
        full = os.path.join(root, name)
        if not os.path.isfile(full):
            continue
        with open(full, "rb") as f:
            body = f.read()
        digest.update(f"{name}\0{len(body)}\0".encode())
        digest.update(body)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--tool", default="")
    parser.add_argument("--plant")
    args = parser.parse_args()
    print(key(args.root, tool=args.tool, plant=args.plant))


if __name__ == "__main__":
    sys.exit(main())
