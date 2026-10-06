// Behavioural tests for the search-link watcher
// (lib/services/search_link_watcher_shim.dart#buildSearchLinkWatcherShim).
//
// The watcher reports the top document's OpenSearch description links and
// its generator meta once, after the load event (LIR-035). The app fetches
// and reads the description; the shim never touches the network.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture, runInDom } = require('./helpers/load_shim');

const HANDLER = 'wsSearchLinks';

function boot(headHtml = '', { url = 'https://searx.lan/search?q=x' } = {}) {
  const dom = makeDom({
    url,
    html: `<!doctype html><html><head>${headHtml}</head><body></body></html>`,
  });
  const calls = [];
  const fetches = [];
  dom.window.fetch = (...args) => { fetches.push(args); return new Promise(() => {}); };
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push({ name, args: JSON.parse(JSON.stringify(args)) });
      return Promise.resolve();
    },
  };
  runInDom(dom, readFixture('search_link_watcher/shim.js'));
  return { dom, calls, fetches };
}

function loaded(dom) {
  return new Promise((resolve) => {
    const settle = () => setTimeout(resolve, 10);
    if (dom.window.document.readyState === 'complete') settle();
    else dom.window.addEventListener('load', settle, { once: true });
  });
}

const SEARX_HEAD =
  '<meta name="generator" content="searxng/2026.7.20">' +
  '<link title="Searx Belgium" type="application/opensearchdescription+xml" ' +
  'rel="search" href="/opensearch.xml?method=POST&amp;autocomplete=google">';

test('reports a SearXNG page once, href resolved, with its generator', async () => {
  const w = boot(SEARX_HEAD);
  await loaded(w.dom);
  assert.equal(w.calls.length, 1);
  assert.equal(w.calls[0].name, HANDLER);
  assert.deepEqual(w.calls[0].args, [{
    links: [{
      href: 'https://searx.lan/opensearch.xml?method=POST&autocomplete=google',
      title: 'Searx Belgium',
    }],
    generator: 'searxng/2026.7.20',
  }]);
});

test('reads the generator wherever it sits in <head>', async () => {
  const w = boot(
    '<link rel="search" type="application/opensearchdescription+xml" href="/a.xml">' +
    '<link rel="search" type="application/opensearchdescription+xml" href="/b.xml">' +
    '<link rel="search" type="application/opensearchdescription+xml" href="/c.xml">' +
    '<link rel="search" type="application/opensearchdescription+xml" href="/d.xml">' +
    '<link rel="search" type="application/opensearchdescription+xml" href="/e.xml">' +
    '<meta name="generator" content="searx/1.1.0">');
  await loaded(w.dom);
  const report = w.calls[0].args[0];
  assert.equal(report.generator, 'searx/1.1.0');
  assert.equal(report.links.length, 4, 'at most four links are reported');
});

test('ignores links that are not OpenSearch descriptions', async () => {
  const w = boot(
    '<link rel="search" href="/search">' +
    '<link rel="alternate" type="application/opensearchdescription+xml" href="/x.xml">' +
    '<link rel="icon" href="/favicon.ico">');
  await loaded(w.dom);
  assert.deepEqual(w.calls, [], 'nothing to report, so no report');
});

test('rel and type match case-insensitively, rel as a token list', async () => {
  const w = boot(
    '<link rel="Search Alternate" type="Application/OpenSearchDescription+XML" href="/os.xml" title="T">');
  await loaded(w.dom);
  assert.deepEqual(w.calls[0].args[0].links,
    [{ href: 'https://searx.lan/os.xml', title: 'T' }]);
});

test('never fetches anything itself', async () => {
  const w = boot(SEARX_HEAD);
  await loaded(w.dom);
  assert.deepEqual(w.fetches, []);
});

test('a subframe reports nothing', async () => {
  const w = boot('<iframe src="about:blank"></iframe>');
  await loaded(w.dom);
  const frame = w.dom.window.document.querySelector('iframe').contentWindow;
  const calls = [];
  frame.flutter_inappwebview = {
    callHandler(name) { calls.push(name); return Promise.resolve(); },
  };
  frame.document.head.innerHTML = SEARX_HEAD;
  frame.eval(readFixture('search_link_watcher/shim.js'));
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(calls, []);
});
