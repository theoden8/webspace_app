// What a coarser clock costs a page and what it denies a fingerprinting
// script, for Tracking Protection's timing quantization (ETP-012), in real
// Chromium. Each candidate clock replaces performance.now() and Date.now()
// the way lib/js/anti_fingerprinting.js does; "the shim" is the shim itself.
//
//   cost     a renderer that yields once 5 ms have passed by
//            performance.now(), as React's scheduler does for transitions:
//            how long each slice holds the main thread
//   leak     how precisely a script times a 50 ms workload: naively (two
//            reads around it), and edge-aligned (start at a tick, count
//            spins to the next one after, each spin calibrated against a
//            whole tick), which reads a floored clock to within one spin
//            however coarse its step. "after 1 s" divides the edge-aligned
//            error by the square root of the samples one second of probing
//            buys, which is what averaging gives when errors are independent;
//            and through event.timeStamp, which no candidate rounds
//
//   node test/browser/perf/clock_precision_bench.js
//
// Not a test (no .test.js), so the browser tier does not run it. WS_PERF_RUNS
// and WS_PERF_OUT work as for typing_bench.js.

const fs = require('node:fs');
const puppeteer = require('puppeteer');
const { pageJs } = require('../../js/helpers/page_js');

const RUNS = Number(process.env.WS_PERF_RUNS) || 5;
const WORK_MS = 50;
const SAMPLES = 24;

// Installs a candidate clock in the page: floored to `precision` ms, or
// with `jitter` rounded up past a threshold drawn per step from `seed`, so
// where a step falls is unknown to the page yet the clock stays monotonic.
function installClock({ precision, jitter, seed }) {
  const proto = Object.getPrototypeOf(performance);
  const origNow = proto.now;
  const origDateNow = Date.now;
  window.__realNow = () => origNow.call(performance);
  function unit(step) {
    let h = (seed ^ Math.imul(step % 4294967296, 0x9e3779b1)) >>> 0;
    h = Math.imul(h ^ (h >>> 16), 0x85ebca6b) >>> 0;
    h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
  }
  function coarsen(t) {
    const step = Math.floor(t / precision);
    if (!jitter) return step * precision;
    return t < (step + unit(step)) * precision ? step * precision : (step + 1) * precision;
  }
  proto.now = function now() { return coarsen(origNow.call(this)); };
  Date.now = function now() { return coarsen(origDateNow.call(Date)); };
}

function keepRealNow() {
  const origNow = Object.getPrototypeOf(performance).now;
  window.__realNow = () => origNow.call(performance);
}

// The fingerprinting script: times a busy loop of `workMs` real ms.
async function probe({ workMs, samples }) {
  const realNow = window.__realNow;
  const now = () => performance.now();
  function work() {
    const start = realNow();
    while (realNow() - start < workMs) { /* the workload */ }
  }
  function edge() {
    const from = now();
    let spins = 0;
    let at = from;
    while (at === from) { at = now(); spins++; }
    return { at, spins };
  }
  const naive = [];
  for (let i = 0; i < samples; i++) {
    const a = now();
    work();
    naive.push(now() - a);
  }
  // Real ms per spin, over whole ticks.
  edge();
  const tickStart = realNow();
  let spins = 0;
  for (let i = 0; i < 4; i++) spins += edge().spins;
  const msPerSpin = (realNow() - tickStart) / spins;
  const aligned = [];
  const began = realNow();
  for (let i = 0; i < samples; i++) {
    const start = edge().at;
    work();
    const after = edge();
    aligned.push(after.at - start - after.spins * msPerSpin);
  }
  const msPerSample = (realNow() - began) / samples;
  // The clock an event carries, which the quantization does not touch.
  const eventTime = () => new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = (e) => resolve(e.timeStamp);
    channel.port2.postMessage(null);
  });
  const viaEvents = [];
  for (let i = 0; i < samples; i++) {
    const a = await eventTime();
    work();
    viaEvents.push((await eventTime()) - a);
  }
  return { naive, aligned, msPerSample, viaEvents };
}

function slicedRendererHtml() {
  return `<!doctype html><html><body><input id="q" autofocus>
    <script>
      window.__slices = [];
      var remaining = 0;
      var channel = new MessageChannel();
      function workLoop() {
        var start = performance.now();
        var sliceStart = window.__realNow();
        while (remaining > 0) {
          var unit = window.__realNow();
          while (window.__realNow() - unit < 1) { /* one unit of render work */ }
          remaining--;
          if (performance.now() - start >= 5) {
            window.__slices.push(window.__realNow() - sliceStart);
            channel.port2.postMessage(null);
            return;
          }
        }
        window.__slices.push(window.__realNow() - sliceStart);
      }
      channel.port1.onmessage = workLoop;
      document.getElementById('q').addEventListener('input', function () {
        var idle = remaining === 0;
        remaining += 60;
        if (idle) channel.port2.postMessage(null);
      });
    </script></body></html>`;
}

async function withClock(page, clock) {
  await page.evaluate(keepRealNow);
  if (clock.shim) await page.addScriptTag({ content: clock.shim });
  if (clock.precision) await page.evaluate(installClock, clock);
}

async function slices(browser, clock) {
  const page = await browser.newPage();
  await page.setContent(slicedRendererHtml());
  await withClock(page, clock);
  await page.focus('#q');
  await page.keyboard.type('x'.repeat(40), { delay: 50 });
  await new Promise((r) => setTimeout(r, 500));
  const all = await page.evaluate(() => window.__slices.slice());
  await page.close();
  return {
    mean: all.reduce((a, b) => a + b, 0) / all.length,
    longest: Math.max(...all),
  };
}

async function leak(browser, clock) {
  const page = await browser.newPage();
  await page.setContent('<!doctype html><html><body></body></html>');
  await withClock(page, clock);
  const r = await page.evaluate(probe, { workMs: WORK_MS, samples: SAMPLES });
  await page.close();
  const rms = (xs) => Math.sqrt(xs.reduce((a, x) => a + (x - WORK_MS) ** 2, 0) / xs.length);
  const aligned = rms(r.aligned);
  return {
    viaEvents: rms(r.viaEvents),
    naive: rms(r.naive),
    aligned,
    msPerSample: r.msPerSample,
    afterOneSecond: aligned / Math.sqrt(Math.max(1, 1000 / r.msPerSample)),
  };
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

async function main() {
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });
  const seed = 0x5eed;
  const clocks = {
    'engine': {},
    'the shim': {
      shim: pageJs('anti_fingerprinting', { seed: 'bench-seed', letterbox: false }),
    },
    '100 ms floor': { precision: 100, jitter: false, seed },
    '16 ms floor': { precision: 16, jitter: false, seed },
    '5 ms floor': { precision: 5, jitter: false, seed },
    '1 ms floor': { precision: 1, jitter: false, seed },
    '100 ms jittered': { precision: 100, jitter: true, seed },
    '16 ms jittered': { precision: 16, jitter: true, seed },
    '5 ms jittered': { precision: 5, jitter: true, seed },
    '2 ms jittered': { precision: 2, jitter: true, seed },
    '1 ms jittered': { precision: 1, jitter: true, seed },
  };
  const rows = [];
  try {
    for (const [name, clock] of Object.entries(clocks)) {
      const cost = [];
      const leaks = [];
      for (let i = 0; i < RUNS; i++) {
        cost.push(await slices(browser, clock));
        leaks.push(await leak(browser, clock));
      }
      const row = {
        clock: name,
        meanSliceMs: median(cost.map((c) => c.mean)),
        longestSliceMs: median(cost.map((c) => c.longest)),
        naiveErrorMs: median(leaks.map((l) => l.naive)),
        alignedErrorMs: median(leaks.map((l) => l.aligned)),
        msPerAlignedSample: median(leaks.map((l) => l.msPerSample)),
        alignedErrorAfter1sMs: median(leaks.map((l) => l.afterOneSecond)),
        eventErrorMs: median(leaks.map((l) => l.viaEvents)),
      };
      rows.push(row);
      if (process.env.WS_PERF_OUT) {
        fs.appendFileSync(process.env.WS_PERF_OUT, `${JSON.stringify(row)}\n`);
      }
    }
  } finally {
    await browser.close();
  }
  const cols = [
    ['clock', 24, (r) => r.clock],
    ['mean slice', 11, (r) => r.meanSliceMs.toFixed(1)],
    ['longest', 8, (r) => r.longestSliceMs.toFixed(1)],
    ['naive err', 10, (r) => r.naiveErrorMs.toFixed(3)],
    ['aligned err', 12, (r) => r.alignedErrorMs.toFixed(3)],
    ['ms/sample', 10, (r) => r.msPerAlignedSample.toFixed(0)],
    ['err after 1 s', 14, (r) => r.alignedErrorAfter1sMs.toFixed(3)],
    ['event.timeStamp err', 20, (r) => r.eventErrorMs.toFixed(3)],
  ];
  console.log(cols.map(([h, w]) => h.padStart(w)).join(' '));
  for (const r of rows) console.log(cols.map(([, w, f]) => String(f(r)).padStart(w)).join(' '));
  console.log(`(ms; ${RUNS} runs each, medians; errors are RMS over ${SAMPLES} timings of ${WORK_MS} ms)`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
