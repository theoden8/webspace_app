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

echo "── WARMSTART: BUG-001 warm-start white screen (PAUSE-020, Attempt 8) ──"
expect warmstart.cfg warmstart.tla "No error has been found" \
  "an attach-triggered nudge repaints every warm-start SurfaceView reattach"
expect warmstart_bug.cfg warmstart.tla "Temporal propert(y|ies).*violated" \
  "a reattach after the resume one-shot nudge drains is left blank (reproduced + caught)"
expect warmstart_reach.cfg warmstart.tla "Reach_LateReattach is violated" \
  "the late-reattach ordering is reachable (RepaintLiveness not vacuous)"

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

echo "── KIOSK: locked shortcut session seals the shell (KIOSK-001/002/003) ──"
expect kiosk.cfg kiosk.tla "No error has been found" \
  "a kiosk-shortcut launch seals chrome + holds fullscreen"
expect kiosk_leak_fs.cfg kiosk.tla "Inv_LockedIsSealed is violated" \
  "exiting fullscreen while locked is caught"
expect kiosk_leak_chrome.cfg kiosk.tla "Inv_LockedIsSealed is violated" \
  "building the drawer while locked is caught"
expect kiosk_reach.cfg kiosk.tla "Reach_Locked is violated" \
  "a locked state is reachable (sealing not vacuous)"

echo "── STORE: secure-storage write serialisation (no lost update) ──"
expect store_serial.cfg store_serial.tla "No error has been found" \
  "every completed read-modify-write's key stays persisted"
expect store_serial_lost.cfg store_serial.tla "Inv_NoLostUpdate is violated" \
  "an unlocked read-modify-write drops a concurrently-committed key (caught)"
expect store_serial_reach.cfg store_serial.tla "Reach_TwoDone is violated" \
  "two ops can both complete (no-lost-update not vacuous)"

echo "── SWITCHGUARD: site-switch version guard vs structural mutation ──"
expect switchguard.cfg switchguard.tla "No error has been found" \
  "a superseded switch bails instead of activating the wrong site"
expect switchguard_noguard.cfg switchguard.tla "Inv_NoWrongActivation is violated" \
  "an unguarded commit after a mutation activates the wrong site (caught)"
expect switchguard_reach.cfg switchguard.tla "Reach_Bailed is violated" \
  "a mutation-during-switch bail is reachable (guard not vacuous)"

echo "── JAR: legacy cookie jar never left empty on a superseded restore ──"
expect jar_nonempty.cfg jar_nonempty.tla "No error has been found" \
  "a nuked jar is always repopulated before returning to rest"
expect jar_nonempty_bail.cfg jar_nonempty.tla "Inv_JarRepopulated is violated" \
  "the post-nuke bail leaves the jar empty when superseded (caught)"
expect jar_nonempty_reach.cfg jar_nonempty.tla "Reach_Nuked is violated" \
  "the nuked jar-empty state is reachable (repopulation not vacuous)"

echo "── PROXY FAIL-CLOSED: a proxied site never egresses directly ──"
expect proxy_failclosed.cfg proxy_failclosed.tla "No error has been found" \
  "a proxied site blanks the load rather than falling back to direct"
expect proxy_failclosed_leak.cfg proxy_failclosed.tla "Inv_NoDirectWhenProxied is violated" \
  "a proxied-but-unbuildable config falling back to direct is caught"
expect proxy_failclosed_reach.cfg proxy_failclosed.tla "Reach_Proxied is violated" \
  "a proxied egress is reachable (fail-closed not vacuous)"

echo "── TRACE CONFORMANCE: code stayed inside the model ──"
case "$JAR" in /*) JAR_ABS="$JAR" ;; *) JAR_ABS="$(pwd)/$JAR" ;; esac
TLA2TOOLS_JAR="$JAR_ABS" ./trace/check_trace.sh | sed 's/^/  /'

echo "All formal checks behaved as expected."
