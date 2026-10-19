# TLC verification profile

Measured on 2026-10-19 with Java 21 and TLC v1.7.4 in a Linux container
limited to two CPU cores. The full verification bounds are unchanged.

## Cold model profile

A 60-second Java Flight Recorder profile sampled the uncached
`activation.cfg` check, after 30 seconds of warmup. It used one worker,
with another TLC check running alongside it. Of 4,669 execution samples,
4,612 came from the model-checking worker.

| Leaf method | Execution samples |
| --- | ---: |
| `Tool.evalApplImpl` | 31.4% |
| `FastTool.evalAppl` | 22.3% |
| `HashMap.getNode` | 11.6% |
| `Tool.getNextStatesImpl` | 4.8% |
| `Tool.getNextStatesApplImpl` | 4.0% |
| `Context.lookup` | 2.7% |
| `RecordValue.normalize` | 2.4% |

These are exclusive leaf samples. The inclusive coverage-wrapper share was
9.2%, overlapping other methods. GC consumed about 3.0 CPU seconds and
1.9 seconds of pauses in the recording. Allocation samples attributed
50.8% of allocation pressure to `IValue[]`, 18.6% to `ActionItemList` and
9.5% to `Context`. Expression evaluation was the first target.

## Reject an inapplicable step before scanning every flow

The printer previously put `Calm` before a step's program-counter guard.
`Calm` scans every flow. Testing `fl[f].pc` first avoids that scan when the
flow is at another place. Both conditions remain conjuncts, and the rest
of the guard and action keep their order. The flow's program counter is
defined for every flow, including `NoFlow`.

The printer retains the declaration order for a parity check.
`test/formal_models_test.dart` prints both orders for the real tables and
every mutant, restores only this adjacent pair's order, and requires the
entire output to match. Dropping or rewriting a condition is caught.
The local comparison of all 207 generated files likewise found only this
permutation in the tables and their proof cases.

Four independent JVM runs compared the orders in alternating order:
baseline, optimized, optimized, baseline. The workload was the base
activation world with `MaxInputs=3`, one worker, a 768 MiB heap, fixed
seed/fingerprint polynomial and the existing coverage collection.
The ordinary checks retain their existing bounds, including
`MaxInputs=4` for the base world.

| Metric | Original order | Program counter first |
| --- | ---: | ---: |
| CPU seconds, first run | 133.226 | 91.871 |
| CPU seconds, second run | 135.990 | 88.558 |
| Median CPU seconds | 134.608 | 90.214 |

Median CPU time decreased by **33.0%** in this workload. Every run produced
1,026,997 generated states, 451,655 distinct states and the same 34 covered
actions. The full cold model checks continued in the background during
these runs, so wall times are not presented as an isolated speedup. This
measurement does not establish a whole-CI improvement.

To repeat, print both guard orders into separate directories, use the same
config, jar, worker count and heap for both, and alternate fresh JVMs.
Retain the TLC outputs and compare verdicts, state totals and the action
sets read by `footprint.taken`. Measure process CPU time separately from
wall time and keep the rest of the machine's load consistent.
