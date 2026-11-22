# Performance benchmarks

Opt-in: `flutter test` skips the Dart files unless their variable is set.

| File | Times | Run |
|---|---|---|
| `startup_bench_test.dart` | the blocker data `main()` loads before `runApp` (DNS list, filter lists), per step, and the longest stall it causes on the UI isolate | `WS_PERF_DATA=<dir> fvm flutter test test/perf/startup_bench_test.dart` |
| `startup_modes_bench_test.dart` | the cold start per mode (launcher, notification tap, background wake; 5 and 40 sites): first frame, the screen it lands on, end of `StartupController.restore` | `WS_PERF=1 fvm flutter test test/perf/startup_modes_bench_test.dart` |
| `url_change_bench_test.dart` | what a page's `history.replaceState` costs the app, same URL and a new URL each time (pages that do it per keystroke) | `WS_PERF=1 fvm flutter test test/perf/url_change_bench_test.dart` |
| [`../browser/perf/typing_bench.js`](../browser/perf/typing_bench.js) | in real Chromium: page-script time per keystroke on a page that re-renders as you type, and how long a time-sliced renderer holds the main thread under the anti-fingerprinting clock | `node test/browser/perf/typing_bench.js` |
| [`../browser/perf/clock_precision_bench.js`](../browser/perf/clock_precision_bench.js) | in real Chromium, per candidate clock for Tracking Protection's timing quantization (ETP-012): how long a time-sliced renderer holds the main thread, and how precisely a page script can still time a workload (naively, aligned to the clock's ticks, and through `event.timeStamp`, which no candidate rounds) | `node test/browser/perf/clock_precision_bench.js` |
| `parity_dump_test.dart` | not a timing: every blocker decision over a corpus built from the raw lists (requests, hosts, cosmetics per page, DNS per level), per launch over one disk while each input of the engine cache changes, to diff two checkouts decision by decision | `WS_PERF_DATA=<dir> WS_PARITY_OUT=<out> fvm flutter test test/perf/parity_dump_test.dart` |

Each prints the median with p10 and p90. `WS_PERF_RUNS=<n>` sets the samples
per measurement (default 5), and `WS_PERF_OUT=<file>` appends every sample as
a JSON line per measurement, for comparing two checkouts by distribution.

The Dart ones run the app's own code with the platform faked, in a JIT test
process on the host: a number is Dart work on the UI isolate (the Android main thread),
without the device's channel or webview latency. Compare runs on one machine,
not against a phone.

The blocker benchmark needs the native engine
(`cargo build --release` in `rust/webspace_adblock`) and the lists the app
downloads, in one directory:

```bash
dir=$(mktemp -d)
for l in light multi pro pro.plus ultimate; do
  curl -fsSL -o "$dir/hagezi-$l.txt" \
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/$l-onlydomains.txt"
done
for l in easylist easyprivacy fanboy-social fanboy-annoyance; do
  curl -fsSL -o "$dir/$l.txt" "https://easylist.to/easylist/$l.txt"
done
```

## Budget gate

`budgets.tsv` is the ceiling each listed measurement may not regress past,
checked in CI (the `Perf budget (report)` job) as a **ratio of this PR's median
over the base's**, both run on the one runner in the one job so the host cancels
out.

**Report-only for now.** The job prints the table and uploads the samples but
does not fail the build; `WS_PERF_BUDGET_ENFORCE=1` turns a breach into a
nonzero exit. A shared CI runner is noisier than a dev box and the job runs head
before base, so the ratio's spread and any order effect are read off the CI runs
first; a follow-up enables enforcement once those show the ceilings have margin.

- `scripts/perf_budget.sh [base-ref]` runs the native-free benchmarks here and
  in a worktree of the base, then compares (`tool/perf/perf_budget.dart`,
  unit-tested by `test/perf_budget_test.dart`). It exits nonzero only when a
  budgeted measurement regressed past its ceiling.
- `ceiling_ratio` is a factor a real regression has to clear, set well above
  run-to-run noise (~7% on the url-change median, wider on the smaller startup
  marks). `floor_ms` skips near-zero measurements whose ratio is noise. Only the
  stable end-to-end marks are gated; the rest ride along as a trend (the samples
  upload as a CI artifact). Raise a ceiling here; never shorten a benchmark to
  pass.
- A measurement new on this PR (absent from the base) is reported, not gated:
  its baseline lands with it and gates the next PR. One master budgets that this
  PR no longer emits fails the gate, so a rename updates `budgets.tsv` too.
