// Behavioural tests for the remote edge script (lib/js/remote_edge.js,
// NAV-016): it names an arrow the page had no use for, so the app can move
// focus out of the page, and stays silent for one the page used. A frame
// passes such an arrow to its parent; test/browser/remote_edge_frames.test.js
// runs that through real cross-origin frames, which jsdom has not (its
// postMessage names no source).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const HANDLER = 'wsRemoteEdge';

const SCRIPT = pageJs('remote_edge', { handler: HANDLER });

// The bridge stand-in, recording what Dart's handler would receive.
function bridge(window) {
  const calls = [];
  window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push({ name, args });
      return Promise.resolve();
    },
  };
  return calls;
}

function boot(bodyHtml = '<a id="a" href="#a">a</a><a id="b" href="#b">b</a>') {
  const dom = makeDom({
    html: `<!doctype html><html><head></head><body>${bodyHtml}</body></html>`,
  });
  const calls = bridge(dom.window);
  runInDom(dom, SCRIPT);
  return { dom, calls, window: dom.window, document: dom.window.document };
}

// A page whose first element is a frame with two buttons, the script running
// in both documents as the webview installs it.
function framed() {
  const top = boot('<iframe id="f"></iframe><a id="a" href="#a">a</a>');
  const iframe = top.document.getElementById('f');
  const child = iframe.contentWindow;
  child.document.body.innerHTML = '<button id="b0">b0</button><button id="b1">b1</button>';
  const childCalls = bridge(child);
  child.eval(SCRIPT);
  const posted = [];
  top.window.addEventListener('message', (e) => posted.push(e.data));
  return { ...top, iframe, child, childCalls, posted };
}

function press(window, key, init = {}) {
  const event = new window.KeyboardEvent('keydown', {
    key, bubbles: true, cancelable: true, ...init,
  });
  (window.document.activeElement ?? window.document.body).dispatchEvent(event);
  return event;
}

// What a frame posts its parent, as a browser delivers it: from the frame's
// own window.
function report(w, { source, direction = 'up', since = Date.now() }) {
  w.window.dispatchEvent(new w.window.MessageEvent('message', {
    data: { __wsRemoteEdge: { direction, since } },
    source,
  }));
}

// Two animation frames, which jsdom runs at 60Hz once it pretends to be
// visual.
const frames = () => new Promise((resolve) => setTimeout(resolve, 80));

// Enough for a later Date.now(), so a key is pressed after the focus that
// set it up.
const later = () => new Promise((resolve) => setTimeout(resolve, 5));

test('an arrow nothing used names its direction (NAV-016)', async () => {
  const w = boot();
  w.document.getElementById('a').focus();
  press(w.window, 'ArrowUp');
  await frames();
  assert.deepEqual(w.calls, [{ name: HANDLER, args: ['up'] }]);
});

test('each arrow names its own direction', async () => {
  const w = boot();
  for (const key of ['ArrowDown', 'ArrowLeft', 'ArrowRight']) press(w.window, key);
  await frames();
  assert.deepEqual(w.calls.map((c) => c.args[0]), ['down', 'left', 'right']);
});

test('an arrow that moved focus was the page\'s', async () => {
  const w = boot();
  const a = w.document.getElementById('a');
  const b = w.document.getElementById('b');
  a.focus();
  a.addEventListener('keydown', () => b.focus());
  press(w.window, 'ArrowDown');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('an arrow the page took is the page\'s', async () => {
  const w = boot();
  w.window.addEventListener('keydown', (e) => e.preventDefault());
  press(w.window, 'ArrowRight');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('an arrow that scrolled anything was the page\'s', async () => {
  const w = boot('<div id="list" style="overflow:auto"></div>');
  const list = w.document.getElementById('list');
  list.addEventListener('keydown', () => {});
  w.window.addEventListener('keydown', () => {
    list.dispatchEvent(new w.dom.window.Event('scroll'));
  });
  press(w.window, 'ArrowDown');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('the arrows stay in a text field, where they move the caret', async () => {
  const w = boot('<input id="q" type="search"><textarea id="t"></textarea>');
  for (const id of ['q', 't']) {
    w.document.getElementById(id).focus();
    press(w.window, 'ArrowLeft');
  }
  await frames();
  assert.deepEqual(w.calls, []);
});

test('a checkbox is not a text field', async () => {
  const w = boot('<input id="c" type="checkbox">');
  w.document.getElementById('c').focus();
  press(w.window, 'ArrowUp');
  await frames();
  assert.deepEqual(w.calls.map((c) => c.args[0]), ['up']);
});

test('a held arrow never leaves, nor one with a modifier', async () => {
  const w = boot();
  press(w.window, 'ArrowDown', { repeat: true });
  press(w.window, 'ArrowLeft', { altKey: true });
  press(w.window, 'ArrowUp', { shiftKey: true });
  await frames();
  assert.deepEqual(w.calls, []);
});

test('other keys are never named', async () => {
  const w = boot();
  press(w.window, 'Enter');
  press(w.window, 'Tab');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('a frame passes an arrow it had no use for to its parent, never to the bridge', async () => {
  const w = framed();
  w.child.document.getElementById('b0').focus();
  press(w.child, 'ArrowUp');
  await frames();
  assert.deepEqual(w.childCalls, []);
  assert.equal(w.posted.length, 1);
  assert.equal(w.posted[0].__wsRemoteEdge.direction, 'up');
  assert.equal(typeof w.posted[0].__wsRemoteEdge.since, 'number');
});

test('a frame keeps an arrow that moved its focus', async () => {
  const w = framed();
  const b0 = w.child.document.getElementById('b0');
  b0.focus();
  b0.addEventListener('keydown', () => w.child.document.getElementById('b1').focus());
  press(w.child, 'ArrowDown');
  await frames();
  assert.deepEqual(w.posted, []);
});

test('the top passes on an arrow from the frame holding its focus (NAV-016)', async () => {
  const w = framed();
  w.iframe.focus();
  assert.equal(w.document.activeElement, w.iframe);
  await later();
  report(w, { source: w.child, direction: 'down' });
  await frames();
  assert.deepEqual(w.calls, [{ name: HANDLER, args: ['down'] }]);
});

test('an arrow from a frame without focus is nobody\'s', async () => {
  const w = framed();
  w.document.getElementById('a').focus();
  await later();
  report(w, { source: w.child });
  report(w, { source: w.window });
  report(w, { source: null });
  await frames();
  assert.deepEqual(w.calls, []);
});

test('an arrow that scrolled above the frame since it was pressed stays', async () => {
  const w = framed();
  w.iframe.focus();
  await later();
  const since = Date.now();
  w.document.dispatchEvent(new w.window.Event('scroll'));
  report(w, { source: w.child, since });
  await frames();
  assert.deepEqual(w.calls, []);
});

test('an arrow after which focus left the frame stays', async () => {
  const w = framed();
  w.iframe.focus();
  await later();
  report(w, { source: w.child });
  w.document.getElementById('a').focus();
  await frames();
  assert.deepEqual(w.calls, []);
});

test('a report naming no direction or no time is dropped', async () => {
  const w = framed();
  w.iframe.focus();
  await later();
  report(w, { source: w.child, direction: 'sideways' });
  w.window.dispatchEvent(new w.window.MessageEvent('message', {
    data: { __wsRemoteEdge: { direction: 'up' } },
    source: w.child,
  }));
  await frames();
  assert.deepEqual(w.calls, []);
});
