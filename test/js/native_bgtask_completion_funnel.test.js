// BGAppRefreshTask completion funnel gate (native concurrency).
//
// `BGTask.setTaskCompleted(success:)` must be called exactly once per task.
// `pendingRefreshTask` is touched from three threads (the BGTaskScheduler
// launch queue, iOS's expirationHandler thread, and the Flutter platform /
// main thread via `bgRefreshDidComplete`), so completion is funnelled onto
// the main queue through a single idempotent `completeTask` helper. A future
// edit that reintroduces a raw `pendingRefreshTask?.setTaskCompleted(...)`
// off that funnel re-opens the double-complete crash / lost-completion race.
//
// No iOS SDK/Xcode is available in CI for this repo's Dart+JS test tiers, so
// this is a structural guard (like surface_repaint_funnel) rather than an
// XCTest under ThreadSanitizer.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'ios/Runner/BackgroundTaskPlugin.swift';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

test('a single completeTask funnel exists', () => {
  assert.match(src, /private func completeTask\(_ task: BGAppRefreshTask, success: Bool\)/,
    `${rel} must funnel completion through completeTask(_:success:)`);
});

test('the funnel guards on task identity for idempotency', () => {
  // The guard is what makes a second completion (expiration after Dart's
  // callback, or vice versa) a no-op and stops a stale expiration handler
  // from completing a newer task.
  assert.match(src, /guard pendingRefreshTask === task else \{ return \}/,
    'completeTask must no-op when the pending slot no longer holds this task');
});

test('no raw setTaskCompleted on the pending slot (the racy shape)', () => {
  // The pre-fix bug called `pendingRefreshTask?.setTaskCompleted(...)` and
  // `pending.setTaskCompleted(...)` directly, unsynchronised. Forbid every
  // shape that completes via the shared property instead of a captured task.
  for (const bad of [
    /pendingRefreshTask\?\.setTaskCompleted/,
    /pendingRefreshTask!\.setTaskCompleted/,
    /\bpending\.setTaskCompleted/,
  ]) {
    assert.ok(!bad.test(src),
      `${rel} completes via the shared pending slot (${bad}); route through completeTask instead`);
  }
});

test('setTaskCompleted only appears in the funnel and the register fallback', () => {
  // Exactly two legitimate call sites: the `completeTask` helper, and the
  // static launch-handler fallback for a task that is not a BGAppRefreshTask.
  const count = (src.match(/\.setTaskCompleted\(/g) || []).length;
  assert.equal(count, 2,
    `expected exactly 2 setTaskCompleted( call sites (completeTask + register fallback), found ${count}`);
});

test('pending-slot access is hopped onto the main queue', () => {
  // The handler body and the expiration handler must hop to main so all
  // pendingRefreshTask access serialises on one thread.
  assert.match(src, /DispatchQueue\.main\.async/,
    'handleRefreshTask/expirationHandler must confine pending-slot access to main');
});
