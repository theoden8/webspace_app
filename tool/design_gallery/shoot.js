// Screenshots the design gallery (see lib/design_gallery/main.dart) card by
// card. Flutter web paints into a canvas, so there is nothing to select per
// component: each card is rendered alone at a viewport sized for it, and the
// viewport is the screenshot.
//
//   scripts/design_web.sh gallery
//   node tool/design_gallery/shoot.js [--out build/design_cards] [--port 8099]

const fs = require('node:fs/promises');
const path = require('node:path');
const puppeteer = require('puppeteer');
const { PNG } = require('pngjs');
const { serve, requireBuild } = require('./static_server');
const { chromiumLaunchOptions } = require('./chromium');

// Screens first, same order as the Dart registry.
const CARDS = [
  { id: 'webspaces', width: 400, height: 640 },
  { id: 'webspace-detail', width: 400, height: 640 },
  { id: 'app-settings', width: 400, height: 900 },
  { id: 'add-site', width: 400, height: 740 },
  { id: 'user-scripts', width: 400, height: 740 },
  { id: 'trusted-certificates', width: 400, height: 560 },
  { id: 'location-picker', width: 400, height: 740 },
  { id: 'site-settings', width: 400, height: 900 },
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

// A card that drew nothing is the failure mode Dart tests cannot see: the
// widget tree can be perfectly correct while CanvasKit renders an empty frame
// (missing engine, missing font). Text-only cards like type-scale go to ~0%
// ink when font loading breaks, which is how that regression surfaces here.
// Measured floor across the current cards is 2.1% ink / 38 colors.
const MIN_INK = 0.01;
const MIN_COLORS = 12;

function inkStats(buffer) {
  const png = PNG.sync.read(buffer);
  const counts = new Map();
  for (let i = 0; i < png.data.length; i += 4) {
    const key = `${png.data[i] >> 3},${png.data[i + 1] >> 3},${png.data[i + 2] >> 3}`;
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  const dominant = Math.max(...counts.values());
  return { ink: 1 - dominant / (png.width * png.height), colors: counts.size };
}

async function shoot(page, base, out, { id, width, height }, theme, accent) {
  const suffix = accent === 'blue' ? '' : `__${accent}`;
  const file = path.join(out, `${id}__${theme}${suffix}.png`);
  await page.setViewport({ width, height, deviceScaleFactor: 2 });
  await page.goto(`${base}/index.html?card=${id}&theme=${theme}&accent=${accent}`, { waitUntil: 'load' });
  await page.waitForSelector('flt-glass-pane', { timeout: 30000 });
  await new Promise((r) => setTimeout(r, 900));
  await page.screenshot({ path: file });

  let { ink, colors } = inkStats(await fs.readFile(file));
  // One retry: a first frame can land before the engine has settled, and a
  // false BLANK in CI is worse than three seconds.
  if (ink < MIN_INK || colors < MIN_COLORS) {
    await new Promise((r) => setTimeout(r, 2000));
    await page.screenshot({ path: file });
    ({ ink, colors } = inkStats(await fs.readFile(file)));
  }
  return { file, ink, colors, blank: ink < MIN_INK || colors < MIN_COLORS };
}

(async () => {
  const root = path.resolve(arg('root', 'build/design_gallery'));
  const out = path.resolve(arg('out', 'build/design_cards'));
  const port = Number(arg('port', 8099));
  await requireBuild(root, 'scripts/design_web.sh gallery');
  await fs.mkdir(out, { recursive: true });

  const server = await serve(root, port);
  const base = `http://127.0.0.1:${port}`;
  const browser = await puppeteer.launch({
    ...chromiumLaunchOptions(),
    headless: true,
    args: ['--no-sandbox', '--disable-gpu', '--force-device-scale-factor=1'],
  });

  const errors = [];
  const blank = [];
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
    for (const c of written) {
      const stats = `${(c.ink * 100).toFixed(1)}% ink, ${c.colors} colors`;
      console.log(`${c.blank ? 'BLANK ' : '      '}${path.relative(process.cwd(), c.file)}  (${stats})`);
    }
    console.log(`\n${written.length} cards -> ${path.relative(process.cwd(), out)}`);

    blank.push(...written.filter((c) => c.blank));
  } finally {
    await browser.close();
    server.close();
  }

  if (blank.length) {
    console.error(`\n${blank.length} cards drew (almost) nothing:`);
    for (const c of blank) {
      console.error(`  ${path.basename(c.file)}  ${(c.ink * 100).toFixed(2)}% ink, ${c.colors} colors`);
    }
    console.error('  a blank card usually means the engine or the font never loaded');
    process.exitCode = 1;
  }

  if (errors.length) {
    console.error(`\n${errors.length} page errors:`);
    for (const e of errors.slice(0, 10)) console.error(`  ${e}`);
    process.exitCode = 1;
  }
})();
