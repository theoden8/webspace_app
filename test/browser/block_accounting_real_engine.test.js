// The page side of "each request counts once" (CB-012) under a real parser,
// a real MutationObserver and real load events: every request the lists
// stop reaches the app once, as an ask or a report, and a request they let
// through goes out. jsdom orders none of this as an engine does, and it was
// an engine's order that counted a parsed <script> twice and let a cached
// verdict for one URL decide its whole host.
//
// WebKit's content rule lists are played by request interception: they stop
// what a path rule names before the page sees it, as the lists do. The
// bridge answers as the app's lists would, and the Bloom filter lands
// before the page's first request or after its first few.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, pageJs } = require('./helpers/launch');
const { listen, closeServer } = require('./helpers/blank_server');

const browser = setupBrowser();

const DNS_HOST = '127.0.0.1';
const PATH_RULE = /\/wsacct-ad\/|\/wsboth\//;

/** The page's requests besides its document: [how, path, on the DNS host]. */
const REQUESTS = [
  ['script', '/wsacct-ad/parsed.js', false],
  ['stylesheet', '/ok/style.css', false],
  ['image', '/ok/a.gif', false],
  ['image', '/wsacct-ad/pixel.gif', false],
  ['fetch', '/ok/data', false],
  ['fetch', '/wsacct-ad/f0', false],
  ['fetch', '/wsacct-ad/f1', false],
  ['fetch', '/x', true],
  ['fetch', '/y', true],
  ['fetch', '/wsboth/z', true],
];

function fnv1a(s, seed) {
  let h = seed >>> 0;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

/** A Bloom filter of [items], hashed as the interceptor reads it. */
function bloomOf(items) {
  const bitCount = 256;
  const k = 3;
  const bits = Buffer.alloc(bitCount / 8);
  for (const s of items) {
    const h1 = fnv1a(s, 0x811C9DC5);
    const h2 = fnv1a(s, 0xCBF29CE4);
    for (let i = 0; i < k; i++) {
      const pos = ((h1 + i * h2) >>> 0) % bitCount;
      bits[pos >> 3] |= 1 << (pos & 7);
    }
  }
  return { bits64: bits.toString('base64'), bitCount, k };
}

const hostBloom = bloomOf([DNS_HOST]);
const tokenBloom = bloomOf(['wsacct', 'wsboth']);
const BLOOM = {
  ...hostBloom,
  tokenBits64: tokenBloom.bits64,
  tokenBitCount: tokenBloom.bitCount,
  tokenK: tokenBloom.k,
  hasGeneric: true,
  genericFallback: false,
};

const blocked = (url) => {
  const u = new URL(url);
  return u.hostname === DNS_HOST || PATH_RULE.test(u.pathname);
};

function pageHtml({ port, inline }) {
  const url = ([, path, dns]) => (dns ? `http://${DNS_HOST}:${port}${path}` : path);
  let head = '';
  let body = '';
  let chain = '';
  for (const r of REQUESTS) {
    switch (r[0]) {
      case 'script': head += `<script src="${url(r)}"></script>\n`; break;
      case 'stylesheet': head += `<link rel="stylesheet" href="${url(r)}">\n`; break;
      case 'image': body += `<img src="${url(r)}">\n`; break;
      case 'fetch': chain += `.then(function(){return fetch('${url(r)}').catch(function(){});})`; break;
    }
  }
  const shim = inline ? `<script>${interceptor}</script>\n` : '';
  return '<!doctype html><html><head><link rel="icon" href="data:,">\n'
    + `${shim}${head}</head><body>\n${body}`
    + `<script>Promise.resolve()${chain}.then(function(){window.__done=true;});</script>\n`
    + '</body></html>';
}

const interceptor = pageJs('block_js_interceptor', { webKitReports: false });

/**
 * Loads the page and returns what arrived at the server and every URL that
 * reached the app, as an ask or a report, with how often.
 */
async function load({ bloomAfterMs, inline }) {
  const arrived = [];
  const server = await listen((req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    arrived.push(`${req.headers.host.split(':')[0]}${req.url}`);
    if (req.url === '/acct') {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.end(pageHtml({ port: server.address().port, inline }));
      return;
    }
    if (req.url.endsWith('.js')) res.setHeader('Content-Type', 'application/javascript');
    res.end('ok');
  });
  const page = await browser.browser.newPage();
  const reached = new Map();
  const reach = (url) => reached.set(url, (reached.get(url) ?? 0) + 1);
  try {
    await page.exposeFunction('__wsBridge', async (name, arg) => {
      switch (name) {
        case 'getBlockBloom':
          await new Promise((r) => setTimeout(r, bloomAfterMs));
          return BLOOM;
        case 'blockCheckBatch':
          for (const ask of arg) reach(ask.url);
          return arg.map((ask) => blocked(ask.url));
        case 'blockRecordBatch':
          for (const record of arg) reach(record.url);
          return null;
        default:
          return null;
      }
    });
    await page.evaluateOnNewDocument(() => {
      window.flutter_inappwebview = { callHandler: (name, arg) => window.__wsBridge(name, arg) };
    });
    if (!inline) await page.evaluateOnNewDocument(interceptor);
    await page.setRequestInterception(true);
    page.on('request', (r) => (PATH_RULE.test(new URL(r.url()).pathname)
      ? r.abort('blockedbyclient') : r.continue()));
    const port = server.address().port;
    await page.goto(`http://localhost:${port}/acct`, { waitUntil: 'load' });
    await page.waitForFunction(() => window.__done === true, { timeout: 15000 });
    // Past the interceptor's batching of what it reports.
    await new Promise((r) => setTimeout(r, 600));
    return { arrived, reached, port };
  } finally {
    await page.close();
    await closeServer(server);
  }
}

for (const inline of [false, true]) {
  for (const bloomAfterMs of [0, 400]) {
    const how = `${inline ? 'inline' : 'at document start'}, bloom after ${bloomAfterMs}ms`;

    test(`each request the lists stop reaches the app once, and the rest go out (${how}) (CB-012)`, async (t) => {
      if (!requireBrowser(browser, t)) return;
      const { arrived, reached, port } = await load({ bloomAfterMs, inline });
      const failures = [];
      for (const [, path, onDnsHost] of REQUESTS) {
        const host = onDnsHost ? DNS_HOST : 'localhost';
        const url = `http://${host}:${port}${path}`;
        const went = arrived.includes(`${host}${path}`);
        const times = reached.get(url) ?? 0;
        if (blocked(url)) {
          if (went) failures.push(`${url} is blocked but went out`);
          if (times !== 1) failures.push(`${url} is blocked and reached the app ${times} times`);
        } else {
          if (!went) failures.push(`${url} is allowed but never went out`);
          if (times > 1) failures.push(`${url} is allowed and was asked ${times} times`);
        }
      }
      assert.deepEqual(failures, [], `arrived: ${arrived.join(', ')}`);
    });
  }
}
