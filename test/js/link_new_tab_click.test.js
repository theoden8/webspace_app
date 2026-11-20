// A link clicked with the platform's new-tab modifier or the middle button
// asks the app for a new tab and does not open the engine's window (TAB-029).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

function boot(modifier) {
  const dom = makeDom();
  const asked = [];
  dom.window.flutter_inappwebview = {
    callHandler: (name, href) => { asked.push([name, href]); },
  };
  runInDom(dom, pageJs('link_new_tab_click', { handler: 'wsLinkNewTab', modifier }));
  dom.window.document.body.innerHTML =
    '<a id="l" href="https://example.org/a"><span id="s">go</span></a>' +
    '<a id="m" href="mailto:x@example.org">mail</a>';
  return { dom, asked };
}

function click(dom, id, init, type = 'click') {
  const ev = new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, ...init });
  dom.window.document.getElementById(id).dispatchEvent(ev);
  return ev;
}

test('Control-click on a link asks for a new tab (TAB-029)', () => {
  const { dom, asked } = boot('ctrlKey');
  const ev = click(dom, 's', { button: 0, ctrlKey: true });
  assert.deepEqual(asked, [['wsLinkNewTab', 'https://example.org/a']]);
  assert.equal(ev.defaultPrevented, true, 'the engine opens no window');
  dom.window.close();
});

test('Command-click asks on a Mac, Control-click does not (TAB-029)', () => {
  const { dom, asked } = boot('metaKey');
  click(dom, 'l', { button: 0, ctrlKey: true });
  assert.deepEqual(asked, [], 'Control-click is a secondary click on a Mac');
  click(dom, 'l', { button: 0, metaKey: true });
  assert.deepEqual(asked, [['wsLinkNewTab', 'https://example.org/a']]);
  dom.window.close();
});

test('a middle click on a link asks for a new tab (TAB-029)', () => {
  const { dom, asked } = boot('ctrlKey');
  const ev = click(dom, 'l', { button: 1 }, 'auxclick');
  assert.deepEqual(asked, [['wsLinkNewTab', 'https://example.org/a']]);
  assert.equal(ev.defaultPrevented, true);
  dom.window.close();
});

test('a plain click and a non-http link are left alone (TAB-029)', () => {
  const { dom, asked } = boot('ctrlKey');
  const plain = click(dom, 'l', { button: 0 });
  assert.equal(plain.defaultPrevented, false);
  const mail = click(dom, 'm', { button: 0, ctrlKey: true });
  assert.equal(mail.defaultPrevented, false);
  assert.deepEqual(asked, []);
  dom.window.close();
});

test('evaluating it again asks once per click (TAB-029)', () => {
  const { dom, asked } = boot('ctrlKey');
  runInDom(dom, pageJs('link_new_tab_click', { handler: 'wsLinkNewTab', modifier: 'ctrlKey' }));
  click(dom, 'l', { button: 0, ctrlKey: true });
  assert.equal(asked.length, 1);
  dom.window.close();
});
