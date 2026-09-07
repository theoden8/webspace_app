// Structural gates for the macOS submission surface. Same failure shape as
// the iOS declarations next door: none of this is code, nothing imports it,
// and every one of these fails after the build — at upload, or at launch on
// someone else's Mac.
//
// Spec: openspec/specs/legal/spec.md (EXPORT-001),
// openspec/specs/platform-support/spec.md (PLATFORM-006).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const repo = path.resolve(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(repo, p), 'utf8');

const INFO_PLIST = 'macos/Runner/Info.plist';
const PBXPROJ = 'macos/Runner.xcodeproj/project.pbxproj';
const WORKFLOW = '.github/workflows/build-and-test.yml';
const GITIGNORE = 'macos/.gitignore';
const SIGN_SCRIPT = 'scripts/sign_macos.sh';

const ENTITLEMENTS = {
  'Runner/Release.entitlements': 'macos/Runner/Release.entitlements',
  'Runner/DebugProfile.entitlements': 'macos/Runner/DebugProfile.entitlements',
};

// An entitlement in the file and its ENABLE_ build setting are two halves of
// one capability: Xcode merges the generated set with the file, and the pair
// disagreeing is how a capability silently half-ships.
const CAPABILITY = {
  'com.apple.security.app-sandbox': 'ENABLE_APP_SANDBOX',
  'com.apple.security.device.camera': 'ENABLE_RESOURCE_ACCESS_CAMERA',
  'com.apple.security.device.audio-input': 'ENABLE_RESOURCE_ACCESS_AUDIO_INPUT',
  'com.apple.security.network.server': 'ENABLE_INCOMING_NETWORK_CONNECTIONS',
  'com.apple.security.network.client': 'ENABLE_OUTGOING_NETWORK_CONNECTIONS',
};

function boolForKey(plist, key) {
  const m = plist.match(new RegExp(`<key>${key}</key>\\s*<(true|false)\\s*/>`));
  return m ? m[1] === 'true' : null;
}

function stringForKey(plist, key) {
  const m = plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`));
  return m ? m[1] : null;
}

/** buildSettings blocks of the Runner target, keyed by entitlements file. */
function runnerBuildSettings() {
  const blocks = read(PBXPROJ).match(/buildSettings = \{[\s\S]*?\n\t{3}\};/g) || [];
  return blocks
    .map((b) => ({ entitlements: (b.match(/CODE_SIGN_ENTITLEMENTS = (\S+);/) || [])[1], body: b }))
    .filter((b) => b.entitlements && b.entitlements.startsWith('Runner/'));
}

test('EXPORT-001: the macOS bundle declares its encryption exempt', () => {
  const plist = read(INFO_PLIST);
  assert.strictEqual(
    boolForKey(plist, 'ITSAppUsesNonExemptEncryption'), false,
    `${INFO_PLIST} must declare ITSAppUsesNonExemptEncryption as false, on ` +
    'the same basis as the iOS bundle. Omitting it stalls every submission ' +
    'on the export-compliance prompt; true obliges a compliance code Apple ' +
    'issues only after approving documentation. See EXPORT-001.',
  );
  assert.strictEqual(
    stringForKey(plist, 'ITSEncryptionExportComplianceCode'), null,
    `${INFO_PLIST} declares encryption exempt but carries a compliance code. ` +
    'An exempt declaration has none.',
  );
});

test('PLATFORM-006: the macOS bundle names an app category', () => {
  const category = stringForKey(read(INFO_PLIST), 'LSApplicationCategoryType');
  assert.match(
    category || '', /^public\.app-category\./,
    `${INFO_PLIST} needs an LSApplicationCategoryType. Mac App Store ` +
    'validation rejects a bundle without one, and it only reports that ' +
    'after the upload.',
  );
});

test('PLATFORM-006: entitlements and sandbox build settings agree', () => {
  for (const { entitlements, body } of runnerBuildSettings()) {
    const file = ENTITLEMENTS[entitlements];
    assert.ok(file, `Unknown entitlements file in ${PBXPROJ}: ${entitlements}`);
    const granted = read(file);
    for (const [key, setting] of Object.entries(CAPABILITY)) {
      if (boolForKey(granted, key) !== true) continue;
      assert.match(
        body, new RegExp(`${setting} = YES;`),
        `${file} grants ${key} but the build configuration using it sets ` +
        `${setting} = NO. Xcode merges the two, so the capability ends up ` +
        'in one and not the other and the failure surfaces at runtime.',
      );
    }
  }
});

test('PLATFORM-006: the CI macOS artifact is re-signed before it is packaged', () => {
  const workflow = read(WORKFLOW);
  assert.match(
    workflow, new RegExp(SIGN_SCRIPT.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
    `${WORKFLOW} builds macOS but never runs ${SIGN_SCRIPT}. The committed ` +
    'entitlements name team-prefixed groups, which an ad-hoc signature ' +
    'cannot back: taskgated SIGKILLs the app at launch as "Code Signature ' +
    'Invalid", so the uploaded artifact runs nowhere.',
  );
  assert.match(
    read(GITIGNORE), /Signing\.local\.xcconfig/,
    `${GITIGNORE} must ignore Signing.local.xcconfig — it carries a signing ` +
    'identity and belongs on the release machine, not in the repo.',
  );
});
