// The drawer's permission badges and the site settings' Permissions row are
// two projections of the same grants. The row once gained Notifications and
// Protected content while the badges did not, so a site whose only grant was
// notifications showed it in settings and nothing in the drawer. This gate
// fails when a capability reaches the row without a drawer badge
// (PERMBADGE-001).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

function functionBody(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `${signature} not found`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}' && --depth === 0) return source.slice(open, i + 1);
  }
  throw new Error(`${signature} is unterminated`);
}

const CAPTURE_LOOP = 'for (final kind in CaptureKind.values)';

test('every capability in the Permissions row has a drawer badge', () => {
  const row = functionBody(read('lib/screens/settings.dart'), 'Widget _buildPermissionsRow()');
  const entries = row.slice(0, row.indexOf('final held'));
  const rowLabels = [...entries.matchAll(/loc\.(siteSettings\w+)/g)].map((m) => m[1]);
  assert.ok(rowLabels.length >= 3, `expected the row's capabilities, found ${rowLabels}`);

  const badgeFile = read('lib/widgets/site_permission_badges.dart');
  const badges = functionBody(badgeFile, 'String sitePermissionBadgeLabel(');
  const badgeLabels = new Set([...badges.matchAll(/loc\.(siteSettings\w+)/g)].map((m) => m[1]));

  // Capture kinds reach both through CaptureKind, so a new kind is badged by
  // construction; what is left to check is that both still loop over it.
  assert.ok(entries.includes(CAPTURE_LOOP), 'the row no longer lists the capture kinds');
  const held = badgeFile.slice(
    badgeFile.indexOf('List<SitePermissionBadge> sitePermissionBadges('),
    badgeFile.indexOf('bool _isRealDeviceAccess('),
  );
  assert.ok(
    held.includes(CAPTURE_LOOP),
    'the row lists every capture kind, so the drawer must badge every one',
  );

  const missing = rowLabels.filter((l) => !badgeLabels.has(l));
  assert.deepEqual(
    missing,
    [],
    'The Permissions row lists a capability the drawer never badges. Add a '
      + 'SitePermissionBadge for it in lib/widgets/site_permission_badges.dart.',
  );
});
