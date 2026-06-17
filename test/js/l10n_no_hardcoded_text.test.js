// Localization invariant LOC-002, ported from the former Dart
// test/l10n_no_hardcoded_text_test.dart so it runs in the Node checks job. A
// migrated UI file must never pass a raw string literal into a user-facing
// display sink; every readable string goes through AppLocalizations.
//
// Migration is phased: `migrated` is enforced and only grows; `pending`
// files are exempt until migrated. Every UI file under the scanned roots
// MUST be in exactly one list so a new screen can't slip past unclassified.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

const migrated = new Set([
  'lib/main.dart',
  'lib/screens/add_site.dart',
  'lib/screens/app_settings.dart',
  'lib/screens/dev_tools.dart',
  'lib/screens/inappbrowser.dart',
  'lib/screens/link_handling_settings.dart',
  'lib/screens/location_picker.dart',
  'lib/screens/settings.dart',
  'lib/screens/site_settings_qr.dart',
  'lib/screens/site_settings_qr_scanner.dart',
  'lib/screens/trusted_certificates.dart',
  'lib/screens/user_scripts.dart',
  'lib/screens/webspace_detail.dart',
  'lib/screens/webspaces_list.dart',
  'lib/widgets/download_button.dart',
  'lib/widgets/external_url_prompt.dart',
  'lib/widgets/find_toolbar.dart',
  'lib/widgets/hint_button.dart',
  'lib/widgets/root_messenger.dart',
  'lib/widgets/stats_banner.dart',
  'lib/widgets/untrusted_cert_prompt.dart',
  'lib/widgets/url_bar.dart',
]);

// Known not-yet-migrated. Shrinks as files move to `migrated`; goal is empty.
const pending = new Set([]);

// Roots scanned for user-facing widgets. Service/model files render no UI.
const scanRoots = ['lib/main.dart', 'lib/screens', 'lib/widgets'];

// Display sinks that put a string directly on screen. A quoted literal
// opening immediately inside any of these is unkeyed text.
const sinkPatterns = [
  /\b(?:Text|SelectableText|Tooltip)\(\s*(?:const\s+)?['"]/g,
  /\b(?:tooltip|hintText|labelText|helperText|errorText|counterText|prefixText|suffixText|semanticLabel)\s*:\s*['"]/g,
];

function discoverDartFiles(roots) {
  const out = new Set();
  const walk = (abs, rel) => {
    for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
      const childAbs = path.join(abs, e.name);
      const childRel = `${rel}/${e.name}`;
      if (e.isDirectory()) walk(childAbs, childRel);
      else if (e.isFile() && e.name.endsWith('.dart')) out.add(childRel);
    }
  };
  for (const root of roots) {
    const abs = path.join(repoRoot, root);
    if (!fs.existsSync(abs)) continue;
    const st = fs.statSync(abs);
    if (st.isFile()) {
      if (root.endsWith('.dart')) out.add(root);
    } else if (st.isDirectory()) {
      walk(abs, root);
    }
  }
  return out;
}

// Naive comment stripping: block comments then line comments (truncate at the
// first `//`). Good enough for the migrated files, which are the only inputs;
// matches the former Dart test's behaviour.
function stripComments(source) {
  const noBlock = source.replace(/\/\*[\s\S]*?\*\//g, '');
  return noBlock
    .split('\n')
    .map((l) => {
      const idx = l.indexOf('//');
      return idx >= 0 ? l.slice(0, idx) : l;
    })
    .join('\n');
}

function findHardcodedDisplayText(rel, source) {
  const stripped = stripComments(source);
  const hits = [];
  for (const p of sinkPatterns) {
    for (const m of stripped.matchAll(p)) {
      const line = (stripped.slice(0, m.index).match(/\n/g) || []).length + 1;
      const snippet = stripped.slice(m.index, m.index + 60).split('\n')[0].trim();
      hits.push(`  ${rel}:${line}: ${snippet}`);
    }
  }
  hits.sort();
  return hits;
}

const setDiff = (a, b) => [...a].filter((x) => !b.has(x));

test('every scanned UI file is classified as migrated or pending', () => {
  const discovered = discoverDartFiles(scanRoots);
  const classified = new Set([...migrated, ...pending]);

  assert.deepEqual(
    setDiff(discovered, classified),
    [],
    'New UI file(s) are not classified. Add each to `migrated` (after routing every string through '
      + 'AppLocalizations) or `pending` in test/js/l10n_no_hardcoded_text.test.js.',
  );
  assert.deepEqual(
    setDiff(classified, discovered),
    [],
    'Classified file(s) no longer exist; drop them from the lists.',
  );
  assert.deepEqual(
    [...migrated].filter((f) => pending.has(f)),
    [],
    'A file is listed as both migrated and pending.',
  );
});

test('migrated files contain no hardcoded user-facing text', () => {
  const violations = [];
  for (const rel of migrated) {
    const abs = path.join(repoRoot, rel);
    assert.ok(fs.existsSync(abs), `Missing migrated file: ${rel}`);
    violations.push(...findHardcodedDisplayText(rel, fs.readFileSync(abs, 'utf8')));
  }
  assert.deepEqual(
    violations,
    [],
    `Hardcoded user-facing string(s) found in migrated files. Route each through AppLocalizations:\n${violations.join('\n')}`,
  );
});
