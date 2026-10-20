"""Merge model shards only when every declared check passed exactly once."""
import argparse
from collections import Counter
from pathlib import Path
import re
import shutil


def registry_records(path):
    lines = [line.split("\t") for line in path.read_text().splitlines()]
    if len(lines) < 2 or len(lines[0]) != 3 or lines[0][0] != "SHARD":
        raise ValueError(f"{path}: missing shard header")
    index, count = map(int, lines[0][1:])
    if count < 1 or not 0 <= index < count:
        raise ValueError(f"{path}: invalid shard")
    records = lines[1:-1]
    for ordinal, row in enumerate(records):
        if (len(row) != 4 or row[:2] != ["CHECK", str(ordinal)]
                or row[3] not in ("holds", "caught", "reached")):
            raise ValueError(f"{path}: malformed check registry")
    if lines[-1] != ["PLANNED", str(len(records))] or not records:
        raise ValueError(f"{path}: incomplete check registry")
    if len({r[2] for r in records}) != len(records):
        raise ValueError(f"{path}: duplicate check names")
    return index, count, records


def merge(root, *, registry, output, coverage):
    manifests = sorted(root.glob("*/manifest.tsv"))
    if not manifests:
        raise ValueError("no model shard manifests")
    _, _, declared = registry_records(registry)
    expected_count = None
    seen_shards = set()
    results = []
    logs = []
    coverage_files = {}
    for path in manifests:
        index, count, records = registry_records(path)
        if index in seen_shards:
            raise ValueError(f"{path}: invalid or duplicate shard")
        seen_shards.add(index)
        if expected_count is None:
            expected_count = count
        if count != expected_count or records != declared:
            raise ValueError(f"{path}: check registries differ")
        text = (path.parent / "models.log").read_text()
        actual = re.findall(r"^RESULT\t(\d+)\t([^\t\n]+)\t(holds|caught|reached)$",
                            text, re.M)
        if len(re.findall(r"^RESULT\b.*$", text, re.M)) != len(actual):
            raise ValueError(f"{path}: malformed result")
        want = [tuple(r[1:]) for i, r in enumerate(records) if i % count == index]
        if actual != want:
            raise ValueError(f"{path}: missing, repeated or misplaced check results")
        totals = Counter(r[2] for r in actual)
        tallies = re.findall(r"^TALLY holds=(\d+) caught=(\d+) reached=(\d+)$",
                             text, re.M)
        if (len(re.findall(r"^TALLY\b.*$", text, re.M)) != 1
                or tallies != [tuple(str(totals[k]) for k in ("holds", "caught", "reached"))]):
            raise ValueError(f"{path}: tally differs from completed checks")
        results.extend(actual)
        logs.append(re.sub(r"^TALLY .*\n?", "", text, flags=re.M))
        for source in sorted((path.parent / "coverage").glob("*.log")):
            if source.stem not in {r[1] for r in actual if r[2] == "holds"}:
                raise ValueError(f"{source}: coverage has no completed holding check")
            if source.name in coverage_files:
                raise ValueError(f"{source}: duplicate coverage")
            coverage_files[source.name] = source
    if seen_shards != set(range(expected_count)):
        raise ValueError("missing model shards")
    if sorted(results, key=lambda r: int(r[0])) != [tuple(r[1:]) for r in declared]:
        raise ValueError("the merged results do not cover every declared check once")
    if coverage.exists():
        shutil.rmtree(coverage)
    coverage.mkdir(parents=True)
    for name, source in coverage_files.items():
        shutil.copyfile(source, coverage / name)
    totals = Counter(r[2] for r in results)
    tally = "TALLY " + " ".join(f"{k}={totals[k]}" for k in ("holds", "caught", "reached"))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(logs) + "\n" + tally + "\n")
    print(f"Every declared model check passed once: {len(results)} checks in {expected_count} shards")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--coverage", required=True, type=Path)
    args = parser.parse_args()
    try:
        merge(args.root, registry=args.registry, output=args.out, coverage=args.coverage)
    except (ValueError, OSError) as error:
        parser.exit(1, f"model shards: {error}\n")


if __name__ == "__main__":
    main()
