// Main-thread script time per keystroke in real Chromium, on a page whose
// results list re-renders as the user types (every search-as-you-type UI),
// with and without the page scripts that watch the DOM.
//
//   node test/browser/perf/typing_bench.js
//
// Not a test (no .test.js), so the browser tier does not run it.

const puppeteer = require('puppeteer');
const { pageJs } = require('../../js/helpers/page_js');

const ELEMENTS = 4000;
const KEYSTROKES = 60;

function pageHtml() {
  const rows = [];
  for (let i = 0; i < ELEMENTS; i++) {
    rows.push(`<div class="row row-${i % 50} col-${i % 7}" id="r${i}">row ${i}</div>`);
  }
  return `<!doctype html><html><body>
    <input id="q" autofocus>
    <ul id="results"></ul>
    <main>${rows.join('')}</main>
    <script>
      document.getElementById('q').addEventListener('input', function (e) {
        var list = document.getElementById('results');
        list.textContent = '';
        for (var k = 0; k < 8; k++) {
          var li = document.createElement('li');
          li.className = 'result result-' + k;
          li.textContent = e.target.value + ' ' + k;
          list.appendChild(li);
        }
      });
    </script>
  </body></html>`;
}

// A renderer that works in 1 ms units and yields once 5 ms have passed by
// performance.now(), as React's scheduler does for transitions, re-rendering
// 60 ms of work per keystroke. Records how long each slice held the main
// thread: no keystroke is handled inside one.
function slicedRendererHtml() {
  return `<!doctype html><html><body><input id="q" autofocus>
    <script>
      var origNow = Performance.prototype.now;
      function realNow() { return origNow.call(performance); }
      window.__slices = [];
      var remaining = 0;
      var channel = new MessageChannel();
      function workLoop() {
        var start = performance.now();
        var sliceStart = realNow();
        while (remaining > 0) {
          var unit = realNow();
          while (realNow() - unit < 1) { /* one unit of render work */ }
          remaining--;
          if (performance.now() - start >= 5) {
            window.__slices.push(realNow() - sliceStart);
            channel.port2.postMessage(null);
            return;
          }
        }
        window.__slices.push(realNow() - sliceStart);
      }
      channel.port1.onmessage = workLoop;
      var q = document.getElementById('q');
      q.addEventListener('input', function () {
        var idle = remaining === 0;
        remaining += 60;
        if (idle) channel.port2.postMessage(null);
      });
    </script></body></html>`;
}

async function renderSlices(browser, { scripts }) {
  const page = await browser.newPage();
  await page.setContent(slicedRendererHtml());
  for (const script of scripts) await page.addScriptTag({ content: script });
  await page.focus('#q');
  await page.keyboard.type('x'.repeat(40), { delay: 50 });
  await new Promise((r) => setTimeout(r, 500));
  const slices = await page.evaluate(() => window.__slices.slice());
  await page.close();
  slices.sort((a, b) => a - b);
  const mean = slices.reduce((a, b) => a + b, 0) / slices.length;
  return { mean, longest: slices[slices.length - 1] };
}

function installBridge() {
  window.flutter_inappwebview = {
    callHandler: function () { return Promise.resolve([]); },
  };
}

async function scriptMsPerKeystroke(browser, { scripts }) {
  const page = await browser.newPage();
  await page.setContent(pageHtml());
  await page.evaluate(installBridge);
  for (const script of scripts) await page.addScriptTag({ content: script });
  await page.focus('#q');
  await new Promise((r) => setTimeout(r, 300));
  const before = (await page.metrics()).ScriptDuration;
  await page.keyboard.type('x'.repeat(KEYSTROKES), { delay: 70 });
  await new Promise((r) => setTimeout(r, 300));
  const after = (await page.metrics()).ScriptDuration;
  await page.close();
  return ((after - before) * 1000) / KEYSTROKES;
}

async function main() {
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });
  try {
    const variants = {
      'no page scripts': [],
      'generic_cosmetic': [pageJs('generic_cosmetic')],
    };
    for (const [name, scripts] of Object.entries(variants)) {
      const samples = [];
      for (let i = 0; i < 5; i++) {
        samples.push(await scriptMsPerKeystroke(browser, { scripts }));
      }
      samples.sort((a, b) => a - b);
      console.log(`${name.padEnd(20)} ${samples[2].toFixed(2)} ms script per keystroke`);
    }
    const quantized = pageJs('anti_fingerprinting', { seed: 'bench-seed', letterbox: false });
    for (const [name, scripts] of Object.entries({
      'clock as the engine': [],
      'anti_fingerprinting': [quantized],
    })) {
      const { mean, longest } = await renderSlices(browser, { scripts });
      console.log(`time-sliced renderer, ${name.padEnd(20)} holds the main thread ` +
        `${mean.toFixed(1)} ms per slice, ${longest.toFixed(1)} ms at most`);
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
