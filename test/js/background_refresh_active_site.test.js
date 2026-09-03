// Background-refresh active-site gate.
//
// `_refreshNotificationSites` reloads every notification site. That is correct
// when the app is backgrounded and wrong when it is not: Android's WorkManager
// tick (NOTIF-005-A) fires whenever the Flutter engine is reachable, the
// foreground included, so an ungated handler reloads the page the user is
// currently reading. The handler was written when only iOS's BGAppRefreshTask
// could reach it, where the app is suspended by definition.
//
// The reload happens inside `_WebSpacePageState`, which no widget test can
// drive without a live engine and a wired platform channel, so this is a
// structural guard in the style of native_bgtask_completion_funnel.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/main.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const assignment = src.match(
  /BackgroundTaskService\.instance\.onBackgroundRefresh\s*=([\s\S]*?);\n/);

test('the background-refresh handler is wired', () => {
  assert.ok(assignment, `${rel} must assign onBackgroundRefresh`);
});

test('it is not the bare _refreshNotificationSites tear-off', () => {
  // The tear-off takes excludeActive's default of false, which is the bug.
  assert.doesNotMatch(assignment[1], /^\s*_refreshNotificationSites\s*$/,
    `${rel} must not hand the raw tear-off to onBackgroundRefresh`);
});

test('it passes excludeActive derived from the lifecycle state', () => {
  assert.match(assignment[1], /excludeActive:/,
    `${rel} must pass excludeActive to _refreshNotificationSites`);
  assert.match(assignment[1], /AppLifecycleState\.resumed/,
    `${rel} must derive excludeActive from the resumed lifecycle state`);
});
