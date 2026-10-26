// One page's sub-resource requests through the shipped WebKit interceptor
// (lib/js/block_js_interceptor.js) in jsdom, reporting the `blockCheck` calls
// it makes. test/perf/block_check_bench_test.dart runs it and replays the
// calls into the app's handler; on its own:
//
//   node test/js/perf/block_check_page.js <page.json>
//
// <page.json> carries the page URL, the `getBlockBloom` answer, each URL's
// verdict and the requests as phases. A phase is issued in one task, the way
// a parser chunk or a script inserts what it found, and the page settles
// before the next one. `via` names the path a request takes past the
// interceptor: `parsed` (an element in the markup, seen by the observer),
// `assigned` (a script setting `src`/`href`), `fetch` or `xhr`.
//
// Prints {"phases": [[url, ...], ...]}: the calls each phase made, in order.

'use strict';

const fs = require('node:fs');
const { makeDom, runInDom, pageJs } = require('../helpers/load_shim');

const settle = () => new Promise((r) => setTimeout(r, 0));

async function main() {
  const page = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const dom = makeDom({ url: page.pageUrl });
  const w = dom.window;
  let calls = [];
  w.fetch = () => Promise.resolve('response');
  w.XMLHttpRequest.prototype.send = function () {};
  w.flutter_inappwebview = {
    callHandler(name, url) {
      if (name === 'getBlockBloom') return Promise.resolve(page.bloom);
      if (name !== 'blockCheck') return Promise.resolve(null);
      calls.push(url);
      return Promise.resolve(page.verdicts[url] ?? false);
    },
  };
  runInDom(dom, pageJs('block_js_interceptor'));
  await settle();

  const attr = (tag) => (tag === 'link' ? 'href' : 'src');
  const phases = [];
  for (const phase of page.phases) {
    calls = [];
    const parsed = w.document.createElement('div');
    for (const r of phase) {
      if (r.via === 'parsed') {
        const el = w.document.createElement(r.tag);
        el.setAttribute(attr(r.tag), r.url);
        parsed.appendChild(el);
      } else if (r.via === 'assigned') {
        const el = w.document.createElement(r.tag);
        el[attr(r.tag)] = r.url;
        w.document.body.appendChild(el);
      } else if (r.via === 'fetch') {
        w.fetch(r.url).catch(() => {});
      } else if (r.via === 'xhr') {
        const x = new w.XMLHttpRequest();
        x.open('GET', r.url);
        x.send();
      } else {
        throw new Error(`unknown via: ${r.via}`);
      }
    }
    if (parsed.firstChild) w.document.body.appendChild(parsed);
    for (let i = 0; i < 4; i++) await settle();
    phases.push(calls);
  }
  process.stdout.write(JSON.stringify({ phases }));
  w.close();
}

main();
