// Screenshots the design gallery (see lib/design_gallery/main.dart) card by
// card. Flutter web paints into a canvas, so there is nothing to select per
// component: each card is rendered alone at a viewport sized for it, and the
// viewport is the screenshot.
//
//   flutter build web -t lib/design_gallery/main.dart
//   node tool/design_gallery/shoot.js [--out build/design_cards] [--port 8099]

const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const puppeteer = require('puppeteer');

const CHROMIUM = process.env.PUPPETEER_EXECUTABLE_PATH || '/opt/pw-browsers/chromium';

const CARDS = [
  { id: 'color-roles', width: 900, height: 180 },
  { id: 'type-scale', width: 520, height: 260 },
  { id: 'radius-scale', width: 520, height: 130 },
  { id: 'url-bar', width: 560, height: 140 },
  { id: 'hint-button', width: 360, height: 80 },
  { id: 'tab-corner-button', width: 260, height: 100 },
  { id: 'browser-chrome', width: 560, height: 380 },
];

// CanvasKit asks fonts.gstatic.com for Roboto regardless of the copy the
// gallery registers itself; that request failing is not a card failure.
const BENIGN = /gstatic\.com|Failed to load resource/;

const THEMES = ['light', 'dark'];
const ACCENTS = ['blue'];
const ACCENT_SWEEP = { card: 'color-roles', accents: ['green', 'purple', 'teal'] };

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function serve(root, port) {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png', '.ttf': 'font/ttf', '.otf': 'font/otf', '.symbols': 'text/plain', '.map': 'application/json' };
  const server = http.createServer(async (req, res) => {
    const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = path.join(root, rel === '/' ? '/index.html' : rel);
    try {
      const body = await fs.readFile(file);
      res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  });
  await new Promise((r) => server.listen(port, '127.0.0.1', r));
  return server;
}

async function shoot(page, base, out, { id, width, height }, theme, accent) {
  const suffix = accent === 'blue' ? '' : `__${accent}`;
  const file = path.join(out, `${id}__${theme}${suffix}.png`);
  await page.setViewport({ width, height, deviceScaleFactor: 2 });
  await page.goto(`${base}/index.html?card=${id}&theme=${theme}&accent=${accent}`, { waitUntil: 'load' });
  await page.waitForSelector('flt-glass-pane', { timeout: 30000 });
  await new Promise((r) => setTimeout(r, 900));
  await page.screenshot({ path: file });
  return file;
}

(async () => {
  const root = path.resolve(arg('root', 'build/web'));
  const out = path.resolve(arg('out', 'build/design_cards'));
  const port = Number(arg('port', 8099));
  await fs.mkdir(out, { recursive: true });

  const server = await serve(root, port);
  const base = `http://127.0.0.1:${port}`;
  const browser = await puppeteer.launch({
    executablePath: CHROMIUM,
    headless: true,
    args: ['--no-sandbox', '--disable-gpu', '--force-device-scale-factor=1'],
  });

  const errors = [];
  try {
    const page = await browser.newPage();
    const note = (text) => BENIGN.test(text) || errors.push(text);
    page.on('pageerror', (e) => note(String(e)));
    page.on('console', (m) => m.type() === 'error' && note(m.text()));

    const written = [];
    for (const card of CARDS) {
      for (const theme of THEMES) {
        for (const accent of ACCENTS) {
          written.push(await shoot(page, base, out, card, theme, accent));
        }
      }
    }
    const sweepCard = CARDS.find((c) => c.id === ACCENT_SWEEP.card);
    for (const accent of ACCENT_SWEEP.accents) {
      written.push(await shoot(page, base, out, sweepCard, 'light', accent));
    }
    for (const f of written) console.log(path.relative(process.cwd(), f));
    console.log(`\n${written.length} cards -> ${path.relative(process.cwd(), out)}`);
  } finally {
    await browser.close();
    server.close();
  }

  if (errors.length) {
    console.error(`\n${errors.length} page errors:`);
    for (const e of errors.slice(0, 10)) console.error(`  ${e}`);
    process.exitCode = 1;
  }
})();
