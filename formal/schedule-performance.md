# Schedule verification profile

Measured on 2026-10-19 against master `4a5134ac`, with Flutter 3.44.9,
Dart 3.12.2, and a Linux container limited to two CPU cores. These are local
measurements of a representative workload; they do not establish a speedup
for the complete CI job.

## Workload and CPU samples

The workload selects the shared-jar activation test and its tabbed counterpart:

```sh
SCHEDULE_LENGTH=2 SCHEDULE_STATS=1 \
MODEL_STEPS_DIR=build/schedule-perf/traces \
fvm flutter test --no-pub --reporter expanded \
  --plain-name 'mixed, shared jar, one site signed in: every schedule holds' \
  test/activation_schedules_test.dart
```

Each run completes 1,307 schedules and prunes 288 paths. It writes
`jar_112.json` and `jar_112_tabs.json`. The baseline and optimized files are
byte-identical.

A separate run used `--start-paused --no-dds`, the Dart VM service CPU
sampler at its 1 ms period, and 16,157 samples. The largest relevant
inclusive sample counts were:

| Operation | Baseline samples | After optimization |
| --- | ---: | ---: |
| Frame snapshots (`ActivationWorld._frameState`) | 33.4% | 23.8% |
| Comparing frame snapshots (`_take`) | 11.5% | 9.3% |
| Inserting traces (`StepTraces.add`) | 0.7% | 1.0% |

The second profile contained 13,179 samples. Inclusive percentages can
overlap, and these profiles exclude compiler startup and do not measure
time waiting for the event loop. The final samples before process exit
may be absent. Compression and faster JSON processing therefore were not
the first optimization: frame checking was the measured CPU hotspot.

## Repeated timings

The timing runs did not enable the sampler. The baseline and candidate ran
in alternating order, with one warmup discarded for each checkout and
three measured runs per version. Times include Flutter startup and test
compilation. CPU time includes child processes.

| Metric | Baseline | Optimized |
| --- | ---: | ---: |
| Wall seconds, three warm runs | 22.963, 23.201, 22.617 | 19.263, 18.038, 18.588 |
| Median wall seconds | 22.963 | 18.588 |
| Median user + system CPU seconds | 27.599 | 22.775 |

Median wall time decreased by **19.0%**, and median CPU time by **17.5%**.
All measured runs had the same schedule counts and byte-identical traces.

## Changes supported by the profile

Frame snapshots now capture immutable scalar values, records and ordered
`FrameValues` instead of repeatedly interpolating, joining and comparing
strings. Each collection snapshot copies its list; nested collections are
snapshotted likewise, so subsequent mutations cannot change an earlier snapshot.
The exhaustive switch over `ModelVar` still determines every watched
variable. Comparing frames now checks the old entries and newly added
keys without allocating their union for every segment.

Existing full-run logs also showed substantial imbalance: individual
shared-jar sweeps took about 30 and 36 minutes, and some shards finished
over half an hour before the last one. The largest activation and small-cap
sweeps now distribute scripts across all shards instead of assigning each
whole sweep to one shard. Every script index belongs to exactly one shard.

The seven full-versus-reduced search comparisons previously bypassed the
shard selector and ran in every process. Each comparison now runs whole
on one shard. Named regressions also remain whole. These scheduling changes
need a complete CI run to quantify their contribution to elapsed time.

The driver reports model generation and schedule exploration as separate
phases. Its former `PRINT` heading covered both the roughly 21-second
model write and the roughly 82-minute schedule stage in the last #740 run.

Search bounds, preemption bounds, model actions, invariant definitions and
verification floors are unchanged.

## Reproducing and extending the measurements

Resolve dependencies in both checkouts, then run the command above once
to warm each one and at least three more times in alternating order.
Capture stdout in separate files, retain each run's trace directory, and
measure the entire process with the shell's `time` command. Avoid other
CPU-intensive work during these runs.

For CPU attribution, add `--start-paused --no-dds` and connect DevTools to
the printed VM service URI. Start CPU recording, resume the test, and
inspect `_frameState`, `_take`, state projection and trace insertion.
Do not use a sampled run as an uninstrumented timing result.

When changing shard assignment, merge the resulting traces with
`formal/trace/check_steps.py` and compare the sets of complete parent paths,
action labels and projected states against an unsharded baseline. Comparing
raw node numbers is insufficient because insertion order can differ.
