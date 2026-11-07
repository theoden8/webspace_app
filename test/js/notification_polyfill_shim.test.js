// jsdom tier for the Notification polyfill (lib/js/notification_polyfill.js).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const shim = (notificationsEnabled) => pageJs('notification_polyfill', {
  notificationsEnabled,
});

function setup(fixture) {
  const dom = makeDom();
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, arg) {
      calls.push({ name, arg: arg === undefined ? undefined : JSON.parse(JSON.stringify(arg)) });
      return Promise.resolve('granted');
    },
  };
  dom.window.console.warn = () => {};
  runInDom(dom, fixture);
  return { w: dom.window, calls };
}

test('a granted site posts through the bridge', () => {
  const { w, calls } = setup(shim(true));
  assert.equal(w.Notification.permission, 'granted');
  new w.Notification('Hi', { body: 'there', tag: 't' });
  assert.deepEqual(calls, [{
    name: 'webNotification',
    arg: { title: 'Hi', body: 'there', icon: '', tag: 't' },
  }]);
});

test('a denied site posts nothing', () => {
  const { w, calls } = setup(shim(false));
  assert.equal(w.Notification.permission, 'denied');
  new w.Notification('Hi');
  assert.deepEqual(calls, []);
});

test('the page cannot swap the polyfill out', () => {
  const { w } = setup(shim(true));
  const polyfill = w.Notification;
  w.eval('window.Notification = function () {};');
  assert.equal(w.Notification, polyfill);
});

test('requestPermission asks the bridge and adopts its answer', async () => {
  const { w, calls } = setup(shim(false));
  assert.equal(await w.Notification.requestPermission(), 'granted');
  assert.equal(w.Notification.permission, 'granted');
  assert.equal(calls[0].name, 'webNotificationRequestPermission');
});

test('NOTIF-010: the polyfill tells no frame the site id, in its config or its calls', async () => {
  const { w, calls } = setup(shim(true));
  new w.Notification('Hi');
  await w.Notification.requestPermission();
  assert.deepEqual(calls.map((c) => c.name), ['webNotification', 'webNotificationRequestPermission']);
  assert.ok(!('siteId' in calls[0].arg), 'a post names no site');
  assert.equal(calls[1].arg, undefined, 'a permission request passes nothing');
  assert.ok(!shim(true).includes('siteId'), 'the config names no site');
});
