// Background-refresh active-site gate.
//
// Android's WorkManager tick (NOTIF-005-A) fires whenever the Flutter engine
// is reachable, the foreground included, so an ungated handler reloads the
// page the user is currently reading. The handler was written when only iOS's
// BGAppRefreshTask could reach it, where the app is suspended by definition.
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

test('the foreground branch reloads around the site on screen', () => {
  // The exclusion is ForegroundPollEngine's, unconditionally; it was once a
  // parameter whose default reloaded the page the user was reading.
  assert.match(assignment[1], /AppLifecycleState\.resumed\s*\?\s*_refreshNotificationSites\(\)/,
    `${rel} must reload through _refreshNotificationSites while resumed`);
  const refresh = /Future<void> _refreshNotificationSites\(\) async \{([\s\S]*?)\n  \}/.exec(src);
  assert.ok(refresh, `${rel} must define _refreshNotificationSites`);
  assert.match(refresh[1], /ForegroundPollEngine\.plan\([\s\S]*currentIndex: _currentIndex,/,
    '_refreshNotificationSites must plan with the site on screen');
});

// NOTIF-013: the OS task ends when this handler returns. Handing the
// backgrounded branch anything that returns once reloads are merely issued
// (as _refreshNotificationSites does) lets iOS suspend the app before a page
// has loaded, so no page JS ever runs in a wake.
test('the backgrounded branch runs the wake that waits for the pages', () => {
  assert.match(assignment[1], /_backgroundWake\(\)/,
    `${rel} must run _backgroundWake when the app is not resumed`);
  const wake = /Future<void> _backgroundWake\(\) async \{([\s\S]*?)\n  \}/.exec(src);
  assert.ok(wake, `${rel} must define _backgroundWake`);
  assert.match(wake[1], /await _wakeEngine\.wake\(/,
    '_backgroundWake must await the engine, or it returns before the pages settle');
  const service = fs.readFileSync(
    path.join(repoRoot, 'lib/services/background_task_service.dart'), 'utf8');
  // Only a background-log line may sit between the two: it is recorded while
  // the OS task is still open, so it lands before iOS can suspend the app.
  assert.match(service, /await cb\(\);\s*\n\s*}\s*\n(?:\s*BackgroundLog\.instance\.record\([^;]*\);\s*\n)?\s*await bgRefreshDidComplete\(success: true\);/,
    'the OS task must be completed only after the Dart handler has returned');
});
