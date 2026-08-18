// Shared-design-value gate. Values that belong to the design system live in
// lib/theme/design_tokens.dart (fixed chrome, spacing, radii, motion) and
// lib/theme/accent_theme.dart (anything accent-derived), so a designer has one
// file to edit rather than a literal buried in a widget.
//
// MIGRATED files must not reintroduce raw literals for those values. PENDING
// files have not been converted yet; a new file under lib/widgets or
// lib/screens must be classified either way, which is what stops the list
// silently going stale. Same structure as l10n_no_hardcoded_text.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

const MIGRATED = [
  // Platform-split favicon rendering: geometry comes from the caller, so
  // there is nothing here to tokenise.
  'lib/screens/favicon_image.dart',
  'lib/screens/favicon_image_io.dart',
  'lib/screens/favicon_image_web.dart',
  'lib/widgets/url_bar.dart',
  'lib/widgets/hint_button.dart',
  'lib/widgets/tab_bar_corner_button.dart',
];

const PENDING = [
  'lib/widgets/download_button.dart',
  'lib/widgets/external_url_prompt.dart',
  'lib/widgets/find_toolbar.dart',
  'lib/widgets/root_messenger.dart',
  'lib/widgets/site_permission_badges.dart',
  'lib/widgets/stats_banner.dart',
  'lib/widgets/untrusted_cert_prompt.dart',
  'lib/widgets/virtual_camera_preview.dart',
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
];

// Each rule names the token that replaces it, so a failure says what to do.
const RULES = [
  { re: /Color\(0x[0-9a-fA-F]{6,8}\)/g, token: 'a Chrome.* colour in design_tokens.dart, or an accent role' },
  { re: /BorderRadius\.circular\(\s*\d/g, token: 'Radii.*' },
  { re: /Duration\(\s*milliseconds:\s*\d/g, token: 'Motion.*' },
];

function read(rel) {
  return fs.readFileSync(path.join(repoRoot, rel), 'utf8');
}

test('migrated files carry no raw design literals', () => {
  const offences = [];
  for (const rel of MIGRATED) {
    const src = read(rel);
    for (const { re, token } of RULES) {
      for (const match of src.match(re) || []) {
        offences.push(`${rel}: ${match} -> use ${token}`);
      }
    }
  }
  assert.deepEqual(offences, []);
});

test('every UI file is classified as migrated or pending', () => {
  const listed = new Set([...MIGRATED, ...PENDING]);
  const found = [];
  for (const dir of ['lib/widgets', 'lib/screens']) {
    for (const file of fs.readdirSync(path.join(repoRoot, dir))) {
      if (file.endsWith('.dart')) found.push(`${dir}/${file}`);
    }
  }
  assert.deepEqual(found.filter((f) => !listed.has(f)), [], 'add new UI files to MIGRATED or PENDING');
  assert.deepEqual([...listed].filter((f) => !found.includes(f)), [], 'remove deleted files from the lists');
});

test('the token file is the only home for fixed chrome colours', () => {
  const tokens = read('lib/theme/design_tokens.dart');
  for (const name of ['barLight', 'barDark', 'hairlineLight', 'hairlineDark']) {
    assert.ok(tokens.includes(name), `design_tokens.dart lost Chrome.${name}`);
  }
  // The gallery's radius card must read the scale, not a copy of it.
  assert.match(read('lib/design_gallery/main.dart'), /Radii\.scale/);
});
