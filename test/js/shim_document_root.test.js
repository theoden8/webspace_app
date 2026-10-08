// Gate: no shim makes a node the document's root element (CB-019).
//
// A shim evaluated after commit but before the parser has made <html> (the
// onLoadStart evaluateJavascript path on Android) sees a document with no
// element child. Anything it appends to `document` becomes the root, and the
// parser then drops <html> and the whole page with it (BUG-031). No Dart type
// sees where a script appends, so this runs every script in lib/js, with its
// sample config, against a rootless document instead.

const test = require('node:test');
const assert = require('node:assert/strict');
const { VirtualConsole } = require('jsdom');
const { makeDom, runInDom } = require('./helpers/load_shim');
const { SAMPLES } = require('./helpers/page_js_samples');

for (const [name, source] of Object.entries(SAMPLES)) {
  test(`${name}.js does not become the root of a rootless document`, async () => {
    // Silent: shims that expect a root report errors from their callbacks.
    const dom = makeDom({ virtualConsole: new VirtualConsole() });
    const doc = dom.window.document;
    doc.removeChild(doc.documentElement);
    try {
      runInDom(dom, source);
    } catch (e) {
      // A shim that needs a root may throw here; production never runs it
      // that early. Only what it left behind is this gate's business.
      if (!(e instanceof dom.window.Error)) throw e;
    }
    await new Promise((r) => dom.window.setTimeout(r, 0));
    const root = doc.documentElement;
    dom.window.close();
    assert.equal(root, null,
      `${name}.js appended <${root && root.nodeName.toLowerCase()}> to the document`);
  });
}
