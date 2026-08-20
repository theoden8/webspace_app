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

// The one card that is not a screenshot: an iframe of the real app, uploaded
// to the project separately by pack_app.js because the design project cannot
// build Flutter. Nothing in this bundle contains it; the page just points at
// ../app/index.html, which is either there or it is not.
const LIVE = {
  path: 'screens/live-app.html',
  group: 'Screens',
  title: 'Live app',
  blurb: 'The real WebSpaceApp running in this project, on seeded demo data: drawer, webspace switch, site settings, animations. Everything else in Screens is a screenshot of the same widgets.',
  source: 'lib/design_app/main.dart',
  live: true,
};

// Screens first: they are the point, the element cards support them.
const PAGES = [
  {
    path: 'screens/webspaces.html',
    group: 'Screens',
    title: 'Webspaces',
    blurb: 'The real WebspacesListScreen: the named collections a user switches between, each with its site count, plus edit, delete and drag-reorder affordances.',
    source: 'lib/screens/webspaces_list.dart',
    shots: [['Light', 'webspaces__light.png'], ['Dark', 'webspaces__dark.png']],
  },
  {
    path: 'screens/webspace-detail.html',
    group: 'Screens',
    title: 'Webspace detail',
    blurb: 'The real WebspaceDetailScreen: which sites belong to one collection.',
    source: 'lib/screens/webspace_detail.dart',
    shots: [['Light', 'webspace-detail__light.png'], ['Dark', 'webspace-detail__dark.png']],
  },
  {
    path: 'screens/app-settings.html',
    group: 'Screens',
    title: 'App settings',
    blurb: 'The real AppSettingsScreen: theme mode, all eight accent swatches, tab-strip and interface preferences. The accent row is the same palette the Foundations cards render.',
    source: 'lib/screens/app_settings.dart',
    shots: [['Light', 'app-settings__light.png'], ['Dark', 'app-settings__dark.png']],
  },
  {
    path: 'screens/add-site.html',
    group: 'Screens',
    title: 'Add site',
    blurb: 'The real AddSiteScreen: URL entry with live preview and suggestions.',
    source: 'lib/screens/add_site.dart',
    shots: [['Light', 'add-site__light.png'], ['Dark', 'add-site__dark.png']],
  },
  {
    path: 'screens/user-scripts.html',
    group: 'Screens',
    title: 'User scripts',
    blurb: 'The real UserScriptsScreen. Interactive in the gallery itself, where the add button pushes the real editor.',
    source: 'lib/screens/user_scripts.dart',
    shots: [['Light', 'user-scripts__light.png'], ['Dark', 'user-scripts__dark.png']],
  },
  {
    path: 'screens/trusted-certificates.html',
    group: 'Screens',
    title: 'Trusted certificates',
    blurb: 'The real TrustedCertificatesScreen with two pinned hosts seeded: per-entry copy and delete affordances, fingerprints wrapped as the app wraps them.',
    source: 'lib/screens/trusted_certificates.dart',
    shots: [['Light', 'trusted-certificates__light.png'], ['Dark', 'trusted-certificates__dark.png']],
  },
  {
    path: 'screens/site-settings.html',
    group: 'Screens',
    title: 'Site settings',
    blurb: 'The real per-site SettingsScreen against a seeded site. Tracking Protection is on, so the features it forces (ClearURLs, DNS blocklist) render disabled with their explanatory subtitles, and DNS blocklist additionally shows the amber not-configured warning for missing downloaded data.',
    source: 'lib/screens/settings.dart',
    shots: [['Light', 'site-settings__light.png'], ['Dark', 'site-settings__dark.png']],
  },
  {
    path: 'screens/location-picker.html',
    group: 'Screens',
    title: 'Location picker',
    blurb: 'The real LocationPickerScreen, showing its privacy gate: tiles are only fetched after the user asks, because loading the map reveals the viewed area to the tile server.',
    source: 'lib/screens/location_picker.dart',
    shots: [['Light', 'location-picker__light.png'], ['Dark', 'location-picker__dark.png']],
  },
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

// Whole-screen captures, if any. The gallery cannot render the real screens
// (they live behind main.dart and do not compile for web), so these come from
// integration_test/screenshot_test.dart run against a device: it writes
// <name>-light.png / <name>-dark.png. Drop them in build/design_screens and
// they join the bundle as a Screens group; absent, the bundle is just the
// element cards.
const screensDir = path.resolve('build/design_screens');

function screenPages() {
  if (!fs.existsSync(screensDir)) return [];
  const files = fs.readdirSync(screensDir).filter((f) => f.endsWith('.png'));
  const screens = new Map();
  for (const file of files.sort()) {
    const base = file.replace(/-(light|dark)\.png$/, '').replace(/\.png$/, '');
    const theme = /-dark\.png$/.test(file) ? 'Dark' : 'Light';
    if (!screens.has(base)) screens.set(base, []);
    screens.get(base).push([theme, file]);
  }
  return [...screens.entries()].map(([base, shots]) => ({
    path: `screens/${base}.html`,
    group: 'Screens',
    title: base.replace(/^\d+[-_]/, '').replace(/[-_]/g, ' ').replace(/^./, (c) => c.toUpperCase()),
    blurb: 'Whole screen from the running app, captured on a device.',
    source: 'integration_test/screenshot_test.dart',
    shots: shots.sort((a, b) => a[0].localeCompare(b[0])),
    dir: screensDir,
  }));
}

const commit = execSync('git rev-parse --short HEAD').toString().trim();

const dataUri = (dir, file) => `data:image/png;base64,${fs.readFileSync(path.join(dir, file)).toString('base64')}`;

const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function renderLive(page) {
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
    p.blurb { margin: 0 0 4px; max-width: 62ch; }
    p.source { margin: 0 0 22px; font-size: 12.5px; color: var(--muted); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
    .device { width: 420px; max-width: 100%; height: 780px; border: 1px solid var(--line);
              border-radius: 14px; overflow: hidden; background: var(--frame); }
    iframe { width: 100%; height: 100%; border: 0; display: block; }
    footer { margin-top: 26px; padding-top: 14px; border-top: 1px solid var(--line);
             font-size: 12px; color: var(--muted); }
  </style>
</head>
<body>
  <h1>${escape(page.title)}</h1>
  <p class="blurb">${escape(page.blurb)}</p>
  <p class="source">Rendered from <code>${escape(page.source)}</code></p>
  <div class="device"><iframe src="../app/index.html" title="WebSpace" loading="lazy"></iframe></div>
  <footer>
    Built from commit <code>${commit}</code>. The app takes a few seconds to boot:
    it loads a 12 MB engine before the first frame. State persists in this
    browser, so a stale layout usually means a stale profile, not a stale build.
    Edits belong in the Dart source; a rebuild has to be asked for through
    <code>_requests/refresh.md</code>.
  </footer>
</body>
</html>
`;
}

function render(page) {
  if (page.live) return renderLive(page);
  const shots = page.shots
    .map(([label, file]) => `      <figure>
        <img src="${dataUri(page.dir || cardsDir, file)}" alt="${escape(page.title)}, ${escape(label.toLowerCase())}">
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

// The Design System pane indexes _ds_manifest.json, which is compiled on the
// receiving side only when the whole bundle is uploaded together; a page added
// in a later single-file write stays invisible. Ship the manifest with the
// bundle so the card list always matches the files. The namespace belongs to
// the WebSpace project and must be preserved across uploads.
const MANIFEST_NAMESPACE = 'WebSpace_130d29';

function writeManifest(pages) {
  const manifest = {
    namespace: MANIFEST_NAMESPACE,
    components: [],
    startingPoints: [],
    // Insertion order, not alphabetical: the pane shows Screens first.
    cards: pages.map((p) => ({ path: p.path, group: p.group })),
    templates: [],
    hasThumbnailHtml: false,
    globalCssPaths: [],
    tokens: [],
    themes: [],
    fonts: [],
    brandFonts: [],
    source: 'spa',
  };
  fs.writeFileSync(path.join(outDir, '_ds_manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`_ds_manifest.json  ${manifest.cards.length} cards`);
}

// The project's README is an input, not a derivative: it describes the project
// to whoever works in it, and ships with every bundle so it cannot drift from
// the pages it describes. It is a README and not a CLAUDE.md because the
// design API refuses to write CLAUDE.md or .claude/ into a project, on the
// grounds that they would be instructions to the design agent.
const PROJECT_DOC = path.join(__dirname, 'project', 'README.md');

fs.rmSync(outDir, { recursive: true, force: true });
const pages = [LIVE, ...PAGES, ...screenPages()];
for (const page of pages) {
  const dest = path.join(outDir, page.path);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const html = render(page);
  fs.writeFileSync(dest, html);
  console.log(`${page.path}  ${(Buffer.byteLength(html) / 1024).toFixed(0)} KiB`);
}
fs.copyFileSync(PROJECT_DOC, path.join(outDir, 'README.md'));
console.log('README.md');
writeManifest(pages);
console.log(`\n${pages.length} pages -> ${path.relative(process.cwd(), outDir)}`);
