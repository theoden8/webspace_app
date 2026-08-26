// Structural gates for the two iOS submission declarations that are easy to
// get wrong and impossible to notice: they are not code, nothing imports
// them, no test exercises them, and both fail silently — a wrong
// ITSAppUsesNonExemptEncryption is a false statement on a submission form
// that ships, and a privacy manifest in the wrong file is simply not read.
//
// Spec: openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md
// (TOR-010 export compliance, TOR-011 privacy manifest).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const repo = path.resolve(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(repo, p), 'utf8');
const exists = (p) => fs.existsSync(path.join(repo, p));

const INFO_PLIST = 'ios/Runner/Info.plist';
const PRIVACY_MANIFEST = 'ios/Runner/PrivacyInfo.xcprivacy';
const PBXPROJ = 'ios/Runner.xcodeproj/project.pbxproj';

/** Value of a <key>…</key> followed by <true/> or <false/>. */
function boolForKey(plist, key) {
  const m = plist.match(
    new RegExp(`<key>${key}</key>\\s*<(true|false)\\s*/>`),
  );
  return m ? m[1] === 'true' : null;
}

test('TOR-010: the app declares non-exempt encryption', () => {
  const declared = boolForKey(read(INFO_PLIST), 'ITSAppUsesNonExemptEncryption');
  assert.notStrictEqual(
    declared, null,
    `${INFO_PLIST} must declare ITSAppUsesNonExemptEncryption. Omitting it ` +
    'stalls every submission on the export-compliance prompt.',
  );
  assert.strictEqual(
    declared, true,
    'The app ships its own cryptography (AES at rest in archive_crypto.dart ' +
    'and html_cache_service.dart; tor\'s TLS and onion routing via ' +
    'Tor.framework). Apple\'s exemption covers OS-provided encryption and ' +
    'authentication-only use, so `false` here is a false declaration to ' +
    'Apple, not a guideline nit a review would bounce back. See TOR-010.',
  );
});

test('TOR-011: required-reason APIs are declared in a privacy manifest', () => {
  assert.ok(
    exists(PRIVACY_MANIFEST),
    `${PRIVACY_MANIFEST} is missing. Apple reads required-reason API ` +
    'declarations from a PrivacyInfo.xcprivacy resource.',
  );
  const manifest = read(PRIVACY_MANIFEST);
  assert.match(
    manifest, /<key>NSPrivacyAccessedAPITypes<\/key>/,
    'The privacy manifest must carry NSPrivacyAccessedAPITypes.',
  );
  // Every declared API needs a reason code; a row without one is rejected.
  const apiTypes = (manifest.match(/NSPrivacyAccessedAPIType<\/key>/g) || []).length;
  const reasonBlocks =
    (manifest.match(/NSPrivacyAccessedAPITypeReasons<\/key>/g) || []).length;
  assert.strictEqual(
    apiTypes, reasonBlocks,
    `Each of the ${apiTypes} declared API types needs an ` +
    `NSPrivacyAccessedAPITypeReasons array; found ${reasonBlocks}.`,
  );
});

test('TOR-011: NSPrivacyAccessedAPITypes is not put in Info.plist', () => {
  // The failure this catches is silent: Apple does not read the key from
  // Info.plist, so a declaration parked there is simply absent at review
  // while looking, in the diff, exactly like a declaration that works.
  assert.doesNotMatch(
    read(INFO_PLIST), /NSPrivacyAccessedAPITypes/,
    `${INFO_PLIST} must not declare NSPrivacyAccessedAPITypes — it belongs ` +
    `in ${PRIVACY_MANIFEST}, which is where Apple looks.`,
  );
});

test('TOR-011: the privacy manifest is bundled, not just present on disk', () => {
  // A .xcprivacy that never enters Copy Bundle Resources ships nothing.
  assert.match(
    read(PBXPROJ), /PrivacyInfo\.xcprivacy/,
    `${PRIVACY_MANIFEST} exists but is not referenced by ${PBXPROJ}, so it ` +
    'is not copied into the app bundle and Apple never sees it.',
  );
});

test('TOR-001: nothing hardcodes Tor\'s default SOCKS port', () => {
  // The embedded runtime picks its own port; 9050 may belong to another app
  // on the device (Orbot, Onion Browser). A hardcoded 9050 in the routing
  // path would silently send the user's traffic to whatever answers.
  const torSources = ['lib/services/tor_engine.dart', 'lib/services/tor_service.dart'];
  for (const rel of torSources) {
    if (!exists(rel)) continue;
    const src = read(rel).replace(/^\s*(\/\/.*)$/gm, '');
    assert.doesNotMatch(
      src, /\b9050\b/,
      `${rel} hardcodes port 9050. The runtime reports its own port; read ` +
      'it from the status payload instead.',
    );
  }
});
