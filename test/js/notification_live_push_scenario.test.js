// NOTIF-012: the lifecycle tier's background-delivery scenario must stay a
// test of what users mean by "notifications work".
//
// Scenario F proved only that a reload happened: its page posts a
// notification on every load, which no real site does, its only site was the
// one on screen, and it backgrounded the app for three seconds. It stayed
// green through a process-global JS pause that froze every notification site
// behind a plain one (NOTIF-011) and through a wake that returned before the
// reloaded page had loaded (NOTIF-013). Scenario P exists because of that, and
// each assertion here names one way it could decay back into the same shape.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const harnessRel = 'scripts/run_android_lifecycle_tests.sh';
const harness = fs.readFileSync(path.join(repoRoot, harnessRel), 'utf8');

const heredoc = (name) => {
  const m = new RegExp(`cat > "\\$www/${name}" <<'EOF'\\n([\\s\\S]*?)\\nEOF\\n`)
    .exec(harness);
  assert.ok(m, `${harnessRel} must write ${name}`);
  return m[1];
};

const scenario = (() => {
  const start = harness.indexOf('echo "== Scenario P:');
  assert.ok(start >= 0, `${harnessRel} must run Scenario P`);
  const end = harness.indexOf('echo "== Scenario', start + 1);
  return harness.slice(start, end < 0 ? undefined : end);
})();

test('the page posts only from a server event, never on load', () => {
  const page = heredoc('push.html');
  assert.match(page, /new EventSource\('\/events'\)/,
    'the page must hold a connection to the fixture server');
  const handler = /onmessage\s*=\s*function[^{]*\{([\s\S]*?)\n\s*\};/.exec(page);
  assert.ok(handler, 'the page must post from its message handler');
  assert.match(handler[1], /new Notification\(/);
  const outside = page.replace(handler[0], '');
  assert.ok(!/new Notification\(/.test(outside),
    'a notification posted on load proves a reload, not a delivery');
});

test('the unread count lives on the server', () => {
  const page = heredoc('push.html');
  assert.match(page, /fetch\('\/count'/,
    'the page must learn its count from the server on load');
  assert.match(page, /document\.title = /,
    'the page must show its count in its title, as real sites do');
  assert.match(harness, /if self\.path\.startswith\('\/record\?'\):/);
  assert.match(harness, /if send:\n\s+events\.append\(text\)/,
    'a recorded message must not reach any open stream');
});

test('the notification site is not the one on screen', () => {
  assert.match(scenario,
    /site_json push\.html "\$push_site_id" ',"notificationsEnabled":true'/);
  assert.match(scenario, /--es siteId "\$dark_site_id"/,
    'the launched site must be the plain one, so the notification site is ' +
    'behind it, where the process-global JS pause reaches it (NOTIF-011)');
});

test('the message arrives after a background wait past the freezer debounce', () => {
  const secs = /background_secs="\$\{WS_PUSH_BACKGROUND_SECS:-(\d+)\}"/.exec(scenario);
  assert.ok(secs, 'the background wait must be a named, overridable default');
  assert.ok(Number(secs[1]) >= 30,
    `a ${secs[1]}s background ends inside the cached-app freezer's grace, ` +
    'where the page could still be running');
  const home = scenario.indexOf('adb shell input keyevent 3');
  const wait = scenario.indexOf('sleep "$background_secs"');
  const record = scenario.indexOf('record_message "bg-');
  const wake = scenario.indexOf('NotificationRefreshDebugReceiver', record);
  assert.ok(home >= 0 && home < wait && wait < record && record < wake,
    'order must be: leave the app, wait, record the message, run the wake');
});

test('the wake, not a reload alone, is what has to notify', () => {
  assert.match(scenario, /wait_for_new_notification push-wake /);
  assert.match(scenario, /if \[ "\$loads_after" -le "\$loads_before" \]; then/,
    'the scenario must fail when the notification did not follow a wake reload');
  assert.match(scenario, /background wake done: unread fallback posts=1/,
    'the scenario must see the wake post on behalf of the silent page (NOTIF-014)');
});

test('the scenario runs by default', () => {
  const gate = scenario.match(/WS_RUN_[A-Z_]+/);
  assert.equal(gate, null,
    'Scenario P must not be opt-in: it is the only test of background delivery');
});
