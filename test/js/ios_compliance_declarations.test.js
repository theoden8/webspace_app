// Structural gates for the two iOS submission declarations that are easy to
// get wrong and impossible to notice: they are not code, nothing imports
// them, no test exercises them, and both fail silently — a wrong
// a wrong ITSAppUsesNonExemptEncryption is a false statement on a submission
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
const FASTFILE = 'ios/fastlane/Fastfile';
const COMPLIANCE_CHECK = 'scripts/check_export_compliance.sh';

/** Value of a <key>…</key> followed by <true/> or <false/>. */
function boolForKey(plist, key) {
  const m = plist.match(
    new RegExp(`<key>${key}</key>\\s*<(true|false)\\s*/>`),
  );
  return m ? m[1] === 'true' : null;
}

/** Value of a <key>…</key> followed by <string>…</string>. */
function stringForKey(plist, key) {
  const m = plist.match(
    new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`),
  );
  return m ? m[1] : null;
}

/** Fastlane lane bodies keyed by lane name. */
function lanes(fastfile) {
  return Object.fromEntries(
    fastfile.split(/^  lane :/m).slice(1)
      .map((part) => [part.match(/^(\w+)/)[1], part]),
  );
}

test('TOR-010: the app declares its encryption exempt', () => {
  const declared = boolForKey(read(INFO_PLIST), 'ITSAppUsesNonExemptEncryption');
  assert.notStrictEqual(
    declared, null,
    `${INFO_PLIST} must declare ITSAppUsesNonExemptEncryption. Omitting it ` +
    'stalls every submission on the export-compliance prompt.',
  );
  assert.strictEqual(
    declared, false,
    'EXPORT-001 rests on publicly available source (MIT, 15 CFR ' +
    '734.3(b)(3) note, 742.15(b)(1)), not on Apple\'s OS-provided ' +
    'exemption. The app does ship its own cryptography, and that is not ' +
    'what decides this key. `true` obliges an ' +
    'ITSEncryptionExportComplianceCode that Apple issues only after ' +
    'approving uploaded documentation, so flipping it here rejects every ' +
    'upload with ITMS-90592 until the code exists. See EXPORT-001.',
  );
});

// `true` is only half the declaration: once App Store Connect approves the
// encryption documentation Apple issues a code, and a build declaring `true`
// without it is rejected at upload with ITMS-90592 ("the export compliance
// key value [] ... doesn't match"). It archives and exports cleanly first, so
// the source tree cannot tell the two states apart — which is why the real
// gate is a pre-submission script and this only fixes the shape.
test('TOR-010: the compliance code, if declared, is not empty', () => {
  const plist = read(INFO_PLIST);
  const code = stringForKey(plist, 'ITSEncryptionExportComplianceCode');
  if (code !== null) {
    assert.notStrictEqual(
      code.trim(), '',
      `${INFO_PLIST} declares an empty ITSEncryptionExportComplianceCode. ` +
      'That is the exact value App Store Connect reports as [] when it ' +
      'rejects the upload. Use the code Apple issued, or drop the key.',
    );
  }
  if (boolForKey(plist, 'ITSAppUsesNonExemptEncryption') === false) {
    assert.strictEqual(
      code, null,
      `${INFO_PLIST} declares encryption exempt but still carries an ` +
      'ITSEncryptionExportComplianceCode. An exempt declaration has no code.',
    );
  }
});

// The value of a gate here is that it fails for a *third* deploy lane too,
// which is how this recurs: the check is one line that a new lane forgets,
// and forgetting it costs a full upload round-trip to find out.
test('TOR-010: every lane that uploads a binary checks export compliance', () => {
  assert.ok(
    exists(COMPLIANCE_CHECK),
    `${COMPLIANCE_CHECK} is missing; the deploy lanes call it before upload.`,
  );
  const fastfile = read(FASTFILE);
  assert.match(
    fastfile, new RegExp(COMPLIANCE_CHECK.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
    `${FASTFILE} defines check_export_compliance but never runs ` +
    `${COMPLIANCE_CHECK}.`,
  );

  const uploading = Object.entries(lanes(fastfile)).filter(
    ([, body]) =>
      /upload_to_testflight|upload_to_app_store/.test(body) &&
      !/skip_binary_upload:\s*true/.test(body),
  );
  assert.ok(
    uploading.length > 0,
    `${FASTFILE} has no binary-uploading lane; did the parser break?`,
  );
  for (const [name, body] of uploading) {
    assert.match(
      body, /check_export_compliance/,
      `Lane :${name} uploads a binary to App Store Connect without calling ` +
      'check_export_compliance first. A mismatched export-compliance key is ' +
      'only diagnosed by Apple at upload (ITMS-90592), so the check has to ' +
      'run before the binary is sent. See TOR-010.',
    );
  }
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
  // The embedded runtime picks its own port; 9050 may belong to another
  // tor-embedding app on the device (Onion Browser). A hardcoded 9050 in
  // the routing path would silently send the user's traffic to whatever
  // answers.
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

// Two screens render the ProxyType enum into a dropdown: the per-site block in
// settings.dart and the app-global one in app_settings.dart. Adding TOR taught
// only the first about it, so global Tor was unselectable — the validator
// refused an empty address and the save bailed. The value of a gate here is
// that it fails for a *third* dropdown too, which is how this recurs.
test('TOR-007: every ProxyType dropdown handles TOR', () => {
  const screens = ['lib/screens/settings.dart', 'lib/screens/app_settings.dart'];
  for (const rel of screens) {
    const src = read(rel);
    if (!/DropdownButton<ProxyType>/.test(src)) continue;

    assert.match(
      src, /TorService\.instance\.isAvailable/,
      `${rel} renders a ProxyType dropdown but never consults ` +
      'TorService.isAvailable, so it offers TOR on platforms with no Tor ' +
      'runtime (TOR-007).',
    );
    // The address validator must exempt TOR, or selecting it blocks the save.
    assert.match(
      src, /type == ProxyType\.DEFAULT \|\|\s*\n?\s*.*type == ProxyType\.TOR|ProxyType\.TOR\) \{\s*\n\s*return null/,
      `${rel} validates a proxy address without exempting TOR. TOR carries ` +
      'no address, so the validator rejects the empty field and the save ' +
      'never lands.',
    );
    // And the inert manual fields must be hidden, not written back.
    assert.match(
      src, /!= ProxyType\.TOR/,
      `${rel} never branches on ProxyType.TOR when showing or persisting the ` +
      'manual address/credential fields; under TOR they are inert and must ' +
      'be preserved, not overwritten (PROXY-010).',
    );
  }
});
