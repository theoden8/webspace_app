// Behavioural tests for the remote edge script (lib/js/remote_edge.js,
// NAV-016): it names an arrow the page had no use for, so the app can move
// focus out of the page, and stays silent for one the page used.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const HANDLER = 'wsRemoteEdge';

function boot(bodyHtml = '<a id="a" href="#a">a</a><a id="b" href="#b">b</a>') {
  const dom = makeDom({
    html: `<!doctype html><html><head></head><body>${bodyHtml}</body></html>`,
  });
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push({ name, args });
      return Promise.resolve();
    },
  };
  runInDom(dom, pageJs('remote_edge', { handler: HANDLER }));
  return { dom, calls, document: dom.window.document };
}

function press(dom, key, init = {}) {
  const event = new dom.window.KeyboardEvent('keydown', {
    key, bubbles: true, cancelable: true, ...init,
  });
  (dom.window.document.activeElement ?? dom.window.document.body).dispatchEvent(event);
  return event;
}

// Two animation frames, which jsdom runs at 60Hz once it pretends to be
// visual.
const frames = () => new Promise((resolve) => setTimeout(resolve, 80));

test('an arrow nothing used names its direction (NAV-016)', async () => {
  const w = boot();
  w.document.getElementById('a').focus();
  press(w.dom, 'ArrowUp');
  await frames();
  assert.deepEqual(w.calls, [{ name: HANDLER, args: ['up'] }]);
});

test('each arrow names its own direction', async () => {
  const w = boot();
  for (const key of ['ArrowDown', 'ArrowLeft', 'ArrowRight']) press(w.dom, key);
  await frames();
  assert.deepEqual(w.calls.map((c) => c.args[0]), ['down', 'left', 'right']);
});

test('an arrow that moved focus was the page\'s', async () => {
  const w = boot();
  const a = w.document.getElementById('a');
  const b = w.document.getElementById('b');
  a.focus();
  a.addEventListener('keydown', () => b.focus());
  press(w.dom, 'ArrowDown');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('an arrow the page took is the page\'s', async () => {
  const w = boot();
  w.dom.window.addEventListener('keydown', (e) => e.preventDefault());
  press(w.dom, 'ArrowRight');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('an arrow that scrolled anything was the page\'s', async () => {
  const w = boot('<div id="list" style="overflow:auto"></div>');
  const list = w.document.getElementById('list');
  list.addEventListener('keydown', () => {});
  w.dom.window.addEventListener('keydown', () => {
    list.dispatchEvent(new w.dom.window.Event('scroll'));
  });
  press(w.dom, 'ArrowDown');
  await frames();
  assert.deepEqual(w.calls, []);
});

test('the arrows stay in a text field, where they move the caret', async () => {
  const w = boot('<input id="q" type="search"><textarea id="t"></textarea>');
  for (const id of ['q', 't']) {
    w.document.getElementById(id).focus();
    press(w.dom, 'ArrowLeft');
  }
  await frames();
  assert.deepEqual(w.calls, []);
});

test('a checkbox is not a text field', async () => {
  const w = boot('<input id="c" type="checkbox">');
  w.document.getElementById('c').focus();
  press(w.dom, 'ArrowUp');
  await frames();
  assert.deepEqual(w.calls.map((c) => c.args[0]), ['up']);
});

test('a held arrow never leaves, nor one with a modifier', async () => {
  const w = boot();
  press(w.dom, 'ArrowDown', { repeat: true });
  press(w.dom, 'ArrowLeft', { altKey: true });
  press(w.dom, 'ArrowUp', { shiftKey: true });
  await frames();
  assert.deepEqual(w.calls, []);
});

test('other keys are never named', async () => {
  const w = boot();
  press(w.dom, 'Enter');
  press(w.dom, 'Tab');
  await frames();
  assert.deepEqual(w.calls, []);
});
