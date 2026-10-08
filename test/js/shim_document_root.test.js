// Gate: no shim makes a node the document's root element (CB-019).
//
// A shim evaluated after commit but before the parser has made <html> (the
// onLoadStart evaluateJavascript path on Android) sees a document with no
// element child. Anything it appends to `document` becomes the root, and the
// parser then drops <html> and the whole page with it (BUG-031). Shims are JS
// strings, so no Dart type sees where they append; this runs every dumped
// fixture against a rootless document instead.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { VirtualConsole } = require('jsdom');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const FIXTURES = path.resolve(__dirname, '..', 'js_fixtures');

function fixtures(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) return fixtures(abs);
    return e.name.endsWith('.js') ? [path.relative(FIXTURES, abs)] : [];
  });
}

for (const rel of fixtures(FIXTURES)) {
  test(`${rel} does not become the root of a rootless document`, async () => {
    // Silent: shims that expect a root report errors from their callbacks.
    const dom = makeDom({ virtualConsole: new VirtualConsole() });
    const doc = dom.window.document;
    doc.removeChild(doc.documentElement);
    try {
      runInDom(dom, readFixture(rel));
    } catch (e) {
      // A shim that needs a root may throw here; production never runs it
      // that early. Only what it left behind is this gate's business.
      if (!(e instanceof dom.window.Error)) throw e;
    }
    await new Promise((r) => dom.window.setTimeout(r, 0));
    const root = doc.documentElement;
    dom.window.close();
    assert.equal(root, null,
      `${rel} appended <${root && root.nodeName.toLowerCase()}> to the document`);
  });
}
