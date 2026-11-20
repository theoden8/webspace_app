// US-012: a header's @grant asks for Tampermonkey's GM functions, and
// WebSpace provides none: the editor lists them as not provided, and no
// page script the app installs defines one, so a script that needs them
// sees `typeof GM_xmlhttpRequest === 'undefined'` and can say so instead of
// calling a stand-in that does something else. Every script in lib/js runs
// here with its sample config, as shim_document_root.test.js runs them.

const test = require('node:test');
const assert = require('node:assert/strict');
const { VirtualConsole } = require('jsdom');
const { makeDom, runInDom } = require('./helpers/load_shim');
const { SAMPLES } = require('./helpers/page_js_samples');

/** The GM names a document's global holds. */
function gmNames(window) {
  const names = Object.getOwnPropertyNames(window).filter((n) => /^GM(?:_|$)/.test(n));
  return names.sort();
}

for (const [name, source] of Object.entries(SAMPLES)) {
  test(`US-012: ${name}.js defines no GM function`, async () => {
    const dom = makeDom({ virtualConsole: new VirtualConsole() });
    try {
      runInDom(dom, source);
    } catch (e) {
      if (!(e instanceof dom.window.Error)) throw e;
    }
    await new Promise((r) => dom.window.setTimeout(r, 0));
    const names = gmNames(dom.window);
    dom.window.close();
    assert.deepEqual(names, []);
  });
}

test('US-012: the check sees a GM function a script defines', () => {
  const dom = makeDom({ virtualConsole: new VirtualConsole() });
  runInDom(dom, 'window.GM_xmlhttpRequest = function () {}; window.GM = {};');
  assert.deepEqual(gmNames(dom.window), ['GM', 'GM_xmlhttpRequest']);
  dom.window.close();
});
