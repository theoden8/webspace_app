// The layer map from CLAUDE.md's Coding principles (rule 4), read by the
// layers gate and tool/architecture_health.js.
const { read, files } = require('./source');

const RANK = { platform: 0, values: 1, services: 2, model: 3, ui: 4 };

function layerOf(path) {
  if (/^lib\/(screens|widgets|controllers|theme|design_gallery|design_app)\//.test(path) || path === 'lib/main.dart' || path === 'lib/app.dart') return 'ui';
  if (['lib/web_view_model.dart', 'lib/demo_data.dart', 'lib/diag_seed.dart'].includes(path)) return 'model';
  // A Webspace is a persisted value (id, name, siteIds) importing only uuid.
  if (path === 'lib/webspace_model.dart') return 'values';
  if (/^lib\/(services|third_party)\//.test(path)) return 'services';
  if (/^lib\/(settings|utils|l10n)\//.test(path)) return 'values';
  if (/^lib\/platform\//.test(path)) return 'platform';
  return null;
}

const sources = files('lib', /\.dart$/).filter((f) => !f.startsWith('lib/l10n/gen/'));

function importsOf(file) {
  return [...read(file).matchAll(/^(?:import|export)\s+'package:webspace\/([^']+)'/gm)].map((m) => `lib/${m[1]}`);
}

function upward() {
  const out = [];
  for (const from of sources) {
    const a = layerOf(from);
    if (!a) continue;
    for (const to of importsOf(from)) {
      const b = layerOf(to);
      if (b && RANK[b] > RANK[a]) out.push(`${from} -> ${to}`);
    }
  }
  return out;
}

module.exports = { RANK, layerOf, sources, importsOf, upward };
