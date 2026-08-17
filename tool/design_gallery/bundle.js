// Builds the Claude Design bundle from the screenshotted cards.
//
// One HTML page per card, images embedded as data URIs so each page stands
// alone, first line carrying the @dsCard marker the Design System pane indexes.
// Everything here is derived from build/design_cards; regenerate rather than
// edit.
//
//   node tool/design_gallery/shoot.js
//   node tool/design_gallery/bundle.js [--out build/design_bundle]

const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const cardsDir = path.resolve('build/design_cards');
const outDir = path.resolve(process.argv.includes('--out') ? process.argv[process.argv.indexOf('--out') + 1] : 'build/design_bundle');

const PAGES = [
  {
    path: 'foundations/color-roles.html',
    group: 'Foundations',
    title: 'Color roles',
    blurb: 'ColorScheme roles as the app builds them, from the default blue accent. Rendered from the real scheme, not a copy of it.',
    source: 'lib/theme/accent_theme.dart',
    shots: [['Light', 'color-roles__light.png'], ['Dark', 'color-roles__dark.png']],
  },
  {
    path: 'foundations/accent-variants.html',
    group: 'Foundations',
    title: 'Accent variants',
    blurb: 'The same roles under three of the eight user-selectable accents. onPrimary is chosen by the accent’s luminance, so labels stay legible on light accents.',
    source: 'lib/theme/accent_theme.dart',
    shots: [['Green', 'color-roles__light__green.png'], ['Purple', 'color-roles__light__purple.png'], ['Teal', 'color-roles__light__teal.png']],
  },
  {
    path: 'foundations/type-scale.html',
    group: 'Foundations',
    title: 'Type scale',
    blurb: 'Material text styles at their shipped sizes, in Roboto.',
    source: 'lib/design_gallery/main.dart',
    shots: [['Light', 'type-scale__light.png'], ['Dark', 'type-scale__dark.png']],
  },
  {
    path: 'foundations/corner-radii.html',
    group: 'Foundations',
    title: 'Corner radii',
    blurb: 'The radii in use across the app: 2, 4, 6, 8, 12. Currently inline literals rather than tokens.',
    source: 'lib/design_gallery/main.dart',
    shots: [['Light', 'radius-scale__light.png'], ['Dark', 'radius-scale__dark.png']],
  },
  {
    path: 'components/url-bar.html',
    group: 'Components',
    title: 'URL bar',
    blurb: 'The real UrlBar widget. Lock icon is green on https and grey otherwise; the second row shows the http case.',
    source: 'lib/widgets/url_bar.dart',
    shots: [['Light', 'url-bar__light.png'], ['Dark', 'url-bar__dark.png']],
  },
  {
    path: 'components/hint-button.html',
    group: 'Components',
    title: 'Hint button',
    blurb: 'The real HintButton: an info affordance that opens a titled explanation dialog.',
    source: 'lib/widgets/hint_button.dart',
    shots: [['Light', 'hint-button__light.png'], ['Dark', 'hint-button__dark.png']],
  },
  {
    path: 'components/tab-corner-button.html',
    group: 'Components',
    title: 'Tab corner button',
    blurb: 'The real TabBarCornerButton in both states: resting, and the scaled/raised dragging state.',
    source: 'lib/widgets/tab_bar_corner_button.dart',
    shots: [['Light', 'tab-corner-button__light.png'], ['Dark', 'tab-corner-button__dark.png']],
  },
  {
    path: 'components/browser-chrome.html',
    group: 'Components',
    title: 'Browser chrome',
    blurb: 'The frame around a site. UrlBar and TabBarCornerButton are the real widgets; the app bar is an approximation, and site content is a placeholder because the native WebView does not run in a browser.',
    source: 'lib/design_gallery/main.dart',
    shots: [['Light', 'browser-chrome__light.png'], ['Dark', 'browser-chrome__dark.png']],
  },
];

const commit = execSync('git rev-parse --short HEAD').toString().trim();

const dataUri = (file) => `data:image/png;base64,${fs.readFileSync(path.join(cardsDir, file)).toString('base64')}`;

const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function render(page) {
  const shots = page.shots
    .map(([label, file]) => `      <figure>
        <img src="${dataUri(file)}" alt="${escape(page.title)}, ${escape(label.toLowerCase())}">
        <figcaption>${escape(label)}</figcaption>
      </figure>`)
    .join('\n');

  return `<!-- @dsCard group="${page.group}" -->
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escape(page.title)}</title>
  <style>
    :root { color-scheme: light dark; --bg: #ffffff; --fg: #16181d; --muted: #5c6169; --line: #e2e5ea; --frame: #f4f5f7; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #121318; --fg: #e8eaee; --muted: #9aa0a8; --line: #2c2f36; --frame: #1b1d23; }
    }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 28px; background: var(--bg); color: var(--fg);
           font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    h1 { margin: 0 0 6px; font-size: 20px; font-weight: 600; letter-spacing: -0.01em; }
    p.blurb { margin: 0 0 4px; max-width: 62ch; color: var(--fg); }
    p.source { margin: 0 0 22px; font-size: 12.5px; color: var(--muted); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
    .shots { display: flex; flex-wrap: wrap; gap: 18px; margin: 0; }
    figure { margin: 0; flex: 1 1 320px; min-width: 0; }
    img { display: block; width: 100%; height: auto; border: 1px solid var(--line);
          border-radius: 10px; background: var(--frame); }
    figcaption { margin-top: 7px; font-size: 12.5px; color: var(--muted); }
    footer { margin-top: 26px; padding-top: 14px; border-top: 1px solid var(--line);
             font-size: 12px; color: var(--muted); }
  </style>
</head>
<body>
  <h1>${escape(page.title)}</h1>
  <p class="blurb">${escape(page.blurb)}</p>
  <p class="source">Rendered from <code>${escape(page.source)}</code></p>
  <div class="shots">
${shots}
  </div>
  <footer>
    Screenshot of the running Flutter widgets, captured headless from the design
    gallery at commit <code>${commit}</code>. Edits belong in the Dart source; this
    page is regenerated by <code>tool/design_gallery/bundle.js</code>.
  </footer>
</body>
</html>
`;
}

fs.rmSync(outDir, { recursive: true, force: true });
for (const page of PAGES) {
  const dest = path.join(outDir, page.path);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const html = render(page);
  fs.writeFileSync(dest, html);
  console.log(`${page.path}  ${(Buffer.byteLength(html) / 1024).toFixed(0)} KiB`);
}
console.log(`\n${PAGES.length} pages -> ${path.relative(process.cwd(), outDir)}`);
