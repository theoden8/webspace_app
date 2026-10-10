# Startup benchmarks

Opt-in: `flutter test` skips both files unless their variable is set.

| File | Times | Run |
|---|---|---|
| `startup_bench_test.dart` | the blocker data `main()` loads before `runApp` (DNS list, filter lists), per step, and the longest stall it causes on the UI isolate | `WS_PERF_DATA=<dir> fvm flutter test test/perf/startup_bench_test.dart` |
| `startup_modes_bench_test.dart` | the cold start per mode (launcher, notification tap, background wake; 5 and 40 sites): first frame, the screen it lands on, end of `StartupController.restore` | `WS_PERF=1 fvm flutter test test/perf/startup_modes_bench_test.dart` |

Both run the app's own code with the platform faked, in a JIT test process on
the host: a number is Dart work on the UI isolate (the Android main thread),
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
