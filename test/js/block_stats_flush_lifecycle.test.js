// Protection-report flush funnel gate (STATS-002).
//
// The counters live in memory behind a debounce, so the only thing standing
// between a recorded block and a restart that still shows it is a flush on
// the way out of the foreground. Flushing on `paused` alone is not that:
// desktop never delivers `paused`, and a foreground kill (OOM, force-stop)
// delivers nothing at all. A future edit that narrows the flush back to one
// lifecycle state re-opens "the stats went back to what they were before".

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/main.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

test('the flush is gated on leaving the foreground, not on one state', () => {
  assert.match(
    src,
    /if \(state != AppLifecycleState\.resumed\) \{\s*unawaited\(BlockStatsService\.instance\.flush\(\)\);\s*\}/,
    `${rel} must flush block stats on every non-resumed lifecycle state`);
});

test('there is a single lifecycle flush call', () => {
  // A second call inside a state-specific branch would drift from the funnel
  // above and read as coverage that is not there.
  const calls = src.match(/BlockStatsService\.instance\.flush\(\)/g) ?? [];
  assert.equal(calls.length, 1,
    `${rel} must funnel the lifecycle flush through one call, found ${calls.length}`);
});
