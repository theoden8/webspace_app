// NOTIF-005-A background-refresh scheduling + CI trigger gate.
//
// Two shapes cost the lifecycle tier a red `Build Android` and a wrong
// diagnosis, and both are invisible to any Dart or JVM test:
//
//   1. A `PeriodicWorkRequest` without an initial delay. While
//      `periodCount == 0` WorkManager reports the next run time as the
//      enqueue time itself, so the first period fires seconds after the
//      first notification site is loaded — reloading the page the user just
//      opened, and spending the slot the harness meant to drive.
//   2. Triggering the refresh with `cmd jobscheduler run -f`. Forcing the
//      job bypasses JobScheduler's constraints but not WorkManager's own
//      before-schedule guard, so whether the worker ran at all depended on
//      whether that first slot was still unspent — a race.
//
// No Android runtime is available in this repo's Dart+JS tiers, so this is a
// structural guard (like native_bgtask_completion_funnel).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const pluginRel =
  'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/BackgroundTaskAndroidPlugin.kt';
const receiverRel =
  'android/app/src/debug/kotlin/org/codeberg/theoden8/webspace/NotificationRefreshDebugReceiver.kt';
const manifestRel = 'android/app/src/debug/AndroidManifest.xml';
const harnessRel = 'scripts/run_android_lifecycle_tests.sh';

const plugin = read(pluginRel);
const harness = read(harnessRel);

test('the periodic refresh delays its first period', () => {
  assert.match(plugin, /\.setInitialDelay\(/,
    `${pluginRel} must give the PeriodicWorkRequest an initial delay, or its ` +
    'first period is due at enqueue time');
});

test('the initial delay is one full interval', () => {
  const request = plugin.slice(plugin.indexOf('PeriodicWorkRequestBuilder'));
  const interval = /PeriodicWorkRequestBuilder<NotificationRefreshWorker>\(\s*([A-Z_a-z0-9]+), TimeUnit\.MINUTES/
    .exec(request);
  assert.ok(interval, 'could not read the periodic interval');
  assert.match(request,
    new RegExp(`\\.setInitialDelay\\(${interval[1]}, TimeUnit\\.MINUTES\\)`),
    'the first period must wait the same interval as every later one');
});

test('the debug refresh receiver lives only in the debug source set', () => {
  assert.ok(fs.existsSync(path.join(repoRoot, receiverRel)),
    `${receiverRel} must exist — it is how CI runs the worker on demand`);
  const mainDir = path.join(repoRoot,
    'android/app/src/main/kotlin/org/codeberg/theoden8/webspace');
  assert.ok(!fs.existsSync(path.join(mainDir, 'NotificationRefreshDebugReceiver.kt')),
    'the debug trigger must not be compiled into shippable builds');
  assert.match(read(manifestRel), /NotificationRefreshDebugReceiver/,
    `${manifestRel} must declare the receiver`);
  const mainManifest = read('android/app/src/main/AndroidManifest.xml');
  assert.ok(!/NotificationRefreshDebugReceiver/.test(mainManifest),
    'the main manifest must not declare the debug trigger');
});

test('the harness triggers the refresh through the receiver', () => {
  assert.match(harness, /am broadcast -n "\$pkg\/\.NotificationRefreshDebugReceiver"/,
    `${harnessRel} must drive the refresh through the debug receiver`);
});

test('the harness never forces the WorkManager job', () => {
  // Comments are allowed to name it — that is where the reason lives.
  const code = harness.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  assert.ok(!/cmd jobscheduler run/.test(code),
    `${harnessRel} forces a job again; WorkManager refuses a periodic WorkSpec ` +
    'that is executed before its next run time, so the trigger is a coin flip');
});

test('the harness still asserts the scheduling contract', () => {
  // Dropping the forced run must not drop the assertion that NOTIF-005-A
  // scheduled anything at all — that is the half the one-shot cannot prove.
  assert.match(harness, /dumpsys jobscheduler[\s\S]{0,200}androidx\.work/,
    `${harnessRel} must still assert a WorkManager job exists (NOTIF-005-A)`);
});

test('a failed refresh can tell "never ran" from "never reloaded"', () => {
  assert.match(harness, /NotificationRefreshWorker fired/,
    `${harnessRel} must read the worker's own log line before blaming the ` +
    'engine-dispatch leg');
});
