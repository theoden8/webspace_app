// jsdom tier for the Notification polyfill (lib/js/notification_polyfill.js).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const shim = (notificationsEnabled) => pageJs('notification_polyfill', {
  siteId: 'site-fixture',
  notificationsEnabled,
});

function setup(fixture) {
  const dom = makeDom();
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, arg) {
      calls.push({ name, arg: JSON.parse(JSON.stringify(arg)) });
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
    arg: { title: 'Hi', body: 'there', icon: '', tag: 't',
      siteId: 'site-fixture' },
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
