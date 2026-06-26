#!/usr/bin/env bash
# Verification suite. Fetches tla2tools.jar if absent, then runs:
#
#   GOOD      kernel.cfg                  -> all properties hold
#   NEGATIVE  *_conflict_*.cfg            -> a mutation MUST be caught (anti-vacuity:
#                                            proves the invariant actually constrains)
#   POSITIVE  *_reach_*.cfg               -> a reachability witness MUST be violated
#                                            (anti-inertness: proves the legal behavior
#                                            the green checks rely on is reachable)
#   ARCHIVE   archive*.cfg                -> ARCH-001 byte-identity (self-composition)
#   TRACE     trace/check_trace.sh        -> code stayed inside the model (LogService)
#
# Exit non-zero if any expectation is unmet. CI-wireable.
set -euo pipefail

cd "$(dirname "$0")"

JAR="${TLA2TOOLS_JAR:-tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  echo "Fetching tla2tools.jar…"
  curl -fsSL -o "$JAR" \
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
fi

# Unique -metadir per run, keyed by the cfg name: TLC's default scratch dir is
# states/<timestamp> at one-second granularity, so back-to-back sub-second runs
# collide ("directory already exists"). Each cfg runs exactly once, so its name
# gives a stable, unique metadir. (A shell counter does NOT work here: run is
# invoked in expect's $(...) subshell, so an incremented counter never persists.)
run() { java -cp "$JAR" tlc2.TLC -metadir "states/$1" -config "$1" "$2" 2>&1 || true; }

# expect <cfg> <model.tla> <grep-pattern> <human-label>
expect() {
  local out; out="$(run "$1" "$2")"
  if echo "$out" | grep -qE "$3"; then
    printf '  OK   %-34s %s\n' "$1" "$4"
  else
    echo "$out" | tail -30
    echo "FAIL: $1 did not produce expected outcome ($4)" >&2
    exit 1
  fi
}

echo "── GOOD: full composition holds ──"
expect kernel.cfg kernel.tla "No error has been found" "all properties hold"

echo "── NEGATIVE: each mutation is caught ──"
expect kernel_conflict_repaint.cfg kernel.tla "Temporal properties were violated" \
  "bypass route → RepaintLiveness violated (liveness non-mix)"
expect kernel_conflict_evict.cfg kernel.tla "Inv_CurrentLoaded is violated" \
  "evict-current → Inv_CurrentLoaded violated (safety non-mix)"
expect kernel_conflict_contaminate.cfg kernel.tla "Inv_JarMatchesVisible is violated" \
  "contaminate → Inv_JarMatchesVisible violated (cookie-leak non-mix)"

echo "── POSITIVE: each legal behavior is reachable (witness violated) ──"
expect kernel_reach_surface_attach.cfg kernel.tla "Reach_SurfaceAttach is violated" \
  "a blank surface attach is reachable (RepaintLiveness not vacuous)"
expect kernel_reach_site_switch.cfg kernel.tla "Reach_SiteSwitch is violated" \
  "activating a non-initial site is reachable"
expect kernel_reach_evict_bg.cfg kernel.tla "Reach_EvictBackground is violated" \
  "evicting a backgrounded site is reachable"

echo "── ARCHIVE: ARCH-001 byte-identity (2-safety via self-composition) ──"
expect archive.cfg archive.tla "No error has been found" \
  "app-tier state is byte-identical with/without archives"
expect archive_leak.cfg archive.tla "ByteIdentity is violated" \
  "leaking archive count into app-tier state is caught"
expect archive_reach.cfg archive.tla "Reach_Active is violated" \
  "byte-identity is checked against real archive+write activity (not vacuous)"

echo "── RENDERER: BUG-002 dead-renderer recovery (PAUSE-013 + PAUSE-014) ──"
expect renderer.cfg renderer.tla "No error has been found" \
  "a visible dead renderer is always eventually recovered"
expect renderer_noprobe.cfg renderer.tla "Temporal properties were violated" \
  "without the probe, an offscreen kill leaves a stuck black screen (caught)"
expect renderer_reach.cfg renderer.tla "Reach_VisibleDead is violated" \
  "a visible dead renderer is reachable (Recovered not vacuous)"

echo "── PROXY: mutual exclusion (Android serialises mismatched-proxy sites) ──"
expect proxy.cfg proxy.tla "No error has been found" \
  "every loaded site shares the active proxy"
expect proxy_mismatch.cfg proxy.tla "Inv_ProxyCoherent is violated" \
  "co-loading a mismatched-proxy site is caught"
expect proxy_reach.cfg proxy.tla "Reach_TwoLoaded is violated" \
  "two compatible sites can co-load (coherence not vacuous)"

echo "── RETENTION: memory-pressure cascade + notification retention (PAUSE-006) ──"
expect retention.cfg retention.tla "No error has been found" \
  "current is never evicted and notification sites are evicted last"
expect retention_starve.cfg retention.tla "Inv_NotifLast is violated" \
  "evicting a notification site before a normal one is caught"
expect retention_reach.cfg retention.tla "Reach_NormalEvicted is violated" \
  "a normal site is actually evicted (retention order not vacuous)"

echo "── CONTAINERS: per-site keyspace disjointness (no shared storage) ──"
expect containers.cfg containers.tla "No error has been found" \
  "the site → container binding is injective (per-site isolation)"
expect containers_alias.cfg containers.tla "Inv_Disjoint is violated" \
  "binding two sites to one container is caught"
expect containers_reach.cfg containers.tla "Reach_TwoCreated is violated" \
  "two sites are actually created (disjointness not vacuous)"

echo "── TRACE CONFORMANCE: code stayed inside the model ──"
case "$JAR" in /*) JAR_ABS="$JAR" ;; *) JAR_ABS="$(pwd)/$JAR" ;; esac
TLA2TOOLS_JAR="$JAR_ABS" ./trace/check_trace.sh | sed 's/^/  /'

echo "All formal checks behaved as expected."
