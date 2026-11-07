// jsdom tier for the Notification polyfill (lib/js/notification_polyfill.js).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const shim = (notificationsEnabled) => pageJs('notification_polyfill', {
  notificationsEnabled,
});

// The polyfill asks `webNotificationPermission` at load for this frame's real
// answer, which the Dart handler computes from the platform's frame origin.
// `permission` is what that handler returns for the frame under test.
function setup(fixture, { permission = 'granted' } = {}) {
  const dom = makeDom();
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, arg) {
      calls.push({ name, arg: arg === undefined ? undefined : JSON.parse(JSON.stringify(arg)) });
      if (name === 'webNotificationPermission') return Promise.resolve(permission);
      return Promise.resolve('granted'); // requestPermission
    },
  };
  dom.window.console.warn = () => {};
  runInDom(dom, fixture);
  return { w: dom.window, calls };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const posts = (calls) => calls.filter((c) => c.name === 'webNotification');

test("a frame the handler grants posts through the bridge", async () => {
  const { w, calls } = setup(shim(true), { permission: 'granted' });
  await tick();
  assert.equal(w.Notification.permission, 'granted');
  new w.Notification('Hi', { body: 'there', tag: 't' });
  assert.deepEqual(posts(calls), [{
    name: 'webNotification',
    arg: { title: 'Hi', body: 'there', icon: '', tag: 't' },
  }]);
});

test('a disabled site is denied and posts nothing', async () => {
  const { w, calls } = setup(shim(false), { permission: 'denied' });
  await tick();
  assert.equal(w.Notification.permission, 'denied');
  new w.Notification('Hi');
  assert.deepEqual(posts(calls), []);
});

test('NOTIF-020: a foreign frame never reads the site\'s granted', async () => {
  // Enabled site, but this frame was never granted: the handler answers
  // 'default'. The frame must never see 'granted', before or after the answer.
  const { w, calls } = setup(shim(true), { permission: 'default' });
  assert.equal(w.Notification.permission, 'default',
      'an enabled site starts a frame at default, not granted');
  await tick();
  assert.equal(w.Notification.permission, 'default');
  new w.Notification('Hi');
  assert.deepEqual(posts(calls), [], 'a non-granted frame posts nothing');
});

test('the page cannot swap the polyfill out', () => {
  const { w } = setup(shim(true));
  const polyfill = w.Notification;
  w.eval('window.Notification = function () {};');
  assert.equal(w.Notification, polyfill);
});

test('requestPermission asks the bridge and adopts its answer', async () => {
  const { w, calls } = setup(shim(false), { permission: 'denied' });
  assert.equal(await w.Notification.requestPermission(), 'granted');
  assert.equal(w.Notification.permission, 'granted');
  assert.ok(calls.some((c) => c.name === 'webNotificationRequestPermission'));
});

test('NOTIF-010: the polyfill tells no frame the site id, in its config or its calls', async () => {
  const { w, calls } = setup(shim(true));
  await tick();
  new w.Notification('Hi');
  await w.Notification.requestPermission();
  for (const c of calls) {
    assert.ok(c.arg === undefined || !('siteId' in c.arg), `${c.name} names no site`);
  }
  assert.ok(!shim(true).includes('siteId'), 'the config names no site');
});
