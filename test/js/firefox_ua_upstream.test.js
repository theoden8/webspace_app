// Upstream drift guard for generated Firefox User-Agent strings.
//
// The UA constants in lib/services/user_agent_classifier.dart imitate what
// real Firefox builds send. When upstream changes shape (macOS freeze,
// Safari token, OS version freeze) our strings silently become a
// fingerprintable tell — and sites like x.com bounce UAs whose grammar
// doesn't match any real browser. This test scrapes the two upstream
// sources of truth and diffs them against our constants:
//
//   * gecko (desktop + Android):
//     mozilla-firefox/firefox netwerk/protocol/http/nsHttpHandler.cpp
//   * Firefox for iOS (WebKit/FxiOS):
//     mozilla-mobile/firefox-ios BrowserKit/Sources/Shared/UserAgent.swift
//
// It also exercises the two version-scrape URLs FirefoxUserAgentService
// depends on — the original hg.mozilla.org source died silently when
// Firefox development moved to GitHub in 2025.
//
// Failure semantics: network unreachable (DNS, timeout) → skip, so offline
// dev runs stay green; an HTTP error from a reachable server → FAIL, since
// a moved/dead URL is exactly the drift this test exists to catch.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const classifierSrc = fs.readFileSync(
  path.join(__dirname, '..', '..', 'lib', 'services', 'user_agent_classifier.dart'),
  'utf8',
);
const serviceSrc = fs.readFileSync(
  path.join(__dirname, '..', '..', 'lib', 'services', 'firefox_user_agent_service.dart'),
  'utf8',
);

// Extracts a Dart string constant, joining adjacent-string concatenation
// ('https://…' '…';) the way the Dart compiler does.
function dartString(src, name) {
  const m = src.match(new RegExp(`${name}\\s*=\\s*((?:'[^']*'\\s*)+);`));
  assert.ok(m, `Dart constant ${name} not found`);
  return [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]).join('');
}

function dartInt(src, name) {
  const m = src.match(new RegExp(`${name}\\s*=\\s*(\\d+);`));
  assert.ok(m, `Dart constant ${name} not found`);
  return parseInt(m[1], 10);
}

const ours = {
  linuxToken: dartString(classifierSrc, 'kFirefoxLinuxPlatformToken'),
  macosToken: dartString(classifierSrc, 'kFirefoxMacosPlatformToken'),
  windowsToken: dartString(classifierSrc, 'kFirefoxWindowsPlatformToken'),
  androidToken: dartString(classifierSrc, 'kFirefoxAndroidOsToken'),
  fxiosOsToken: dartString(classifierSrc, '_kFxiosOsToken'),
  fxiosWebKit: dartString(classifierSrc, '_kFxiosWebKit'),
  fxiosMobileBuild: dartString(classifierSrc, '_kFxiosMobileBuild'),
  fxiosSafari: dartString(classifierSrc, '_kFxiosSafari'),
  versionFloor: dartInt(classifierSrc, 'kDefaultFirefoxMajorVersion'),
  sourceVersionUrl: dartString(serviceSrc, '_sourceVersionUrl'),
  productDetailsUrl: dartString(serviceSrc, '_productDetailsUrl'),
};

const GECKO_HTTP_HANDLER_URL =
  'https://raw.githubusercontent.com/mozilla-firefox/firefox/release/' +
  'netwerk/protocol/http/nsHttpHandler.cpp';
const FXIOS_USER_AGENT_URL =
  'https://raw.githubusercontent.com/mozilla-mobile/firefox-ios/main/' +
  'BrowserKit/Sources/Shared/UserAgent.swift';

// null → network unreachable (caller should skip). Throws on HTTP error.
async function fetchTextOrNull(url) {
  let res;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(30000) });
  } catch (e) {
    console.warn(`[firefox_ua_upstream] unreachable, skipping: ${url} (${e})`);
    return null;
  }
  assert.ok(res.ok, `HTTP ${res.status} from ${url} — source moved or dead`);
  return res.text();
}

test('gecko desktop/Android UA components match ours', async (t) => {
  const src = await fetchTextOrNull(GECKO_HTTP_HANDLER_URL);
  if (src === null) return t.skip('network unreachable');

  // macOS oscpu is frozen upstream; our token is "Macintosh; " + that
  // literal. Dots, not the Chrome-style underscores.
  const mac = src.match(/AssignLiteral\("(Intel Mac OS X [^"]+)"\)/);
  assert.ok(mac, 'macOS oscpu literal not found in nsHttpHandler.cpp');
  assert.equal(ours.macosToken, `Macintosh; ${mac[1]}`);

  // Windows oscpu = OSCPU_WINDOWS + the Win64 suffix.
  const winBase = src.match(/define OSCPU_WINDOWS "([^"]+)"/);
  const winSuffix = src.match(/define OSCPU_WIN64 OSCPU_WINDOWS "([^"]+)"/);
  assert.ok(winBase && winSuffix, 'Windows oscpu defines not found');
  assert.equal(ours.windowsToken, `${winBase[1]}${winSuffix[1]}`);

  // Linux: platform "X11" (kept for backwards compatibility) + oscpu.
  assert.ok(src.includes('"X11"'), 'X11 platform literal gone upstream');
  assert.ok(src.includes('"Linux x86_64"'), 'Linux oscpu literal gone upstream');
  assert.equal(ours.linuxToken, 'X11; Linux x86_64');

  // Desktop Gecko trail is still the frozen legacy constant (Android/iOS
  // use the version instead — which buildFirefoxAndroidUserAgent mirrors).
  assert.ok(
    src.includes('LEGACY_UA_GECKO_TRAIL'),
    'desktop no longer uses the legacy Gecko trail — update desktop builders',
  );
  assert.ok(
    classifierSrc.includes('Gecko/20100101'),
    'desktop builders must render the frozen 20100101 trail',
  );

  // Android reports the real OS major for >= 10 and only spoofs older
  // devices up to 10, so our pinned token must be a plausible current
  // major, not the pre-2024 "frozen at 10" behavior.
  assert.ok(
    src.match(/AppendLiteral\("10"\)/),
    'Android spoof-floor changed upstream — re-check kFirefoxAndroidOsToken',
  );
  const androidMajor = ours.androidToken.match(/^Android (\d+)$/);
  assert.ok(androidMajor, `unexpected Android token: ${ours.androidToken}`);
  assert.ok(parseInt(androidMajor[1], 10) >= 10);
});

test('firefox-ios (FxiOS) UA components match ours', async (t) => {
  const src = await fetchTextOrNull(FXIOS_USER_AGENT_URL);
  if (src === null) return t.skip('network unreachable');

  const bit = (name) => {
    const m = src.match(new RegExp(`let ${name} = "([^"]+)"`));
    assert.ok(m, `${name} not found in UserAgent.swift`);
    return m[1];
  };
  // The mobile UA tail ends with Safari/604.1 (Mobile Safari's token),
  // NOT the 605.1.15 WebKit build number upstream reserves for its
  // desktop-mode UA.
  assert.equal(ours.fxiosSafari, bit('uaBitSafari'));
  assert.equal(ours.fxiosMobileBuild, bit('uaBitMobile'));
  assert.equal(ours.fxiosWebKit, `${bit('platform')} ${bit('platformDetails')}`);

  // Upstream freezes the reported iOS version in defaultMobileUserAgent.
  const frozen = src.match(/ OS (\d+_\d+) like Mac OS X/);
  assert.ok(frozen, 'frozen iOS version not found in UserAgent.swift');
  assert.equal(ours.fxiosOsToken, `iPhone; CPU iPhone OS ${frozen[1]} like Mac OS X`);

  // Extension ordering: FxiOS marker, then Mobile build, then Safari bit.
  assert.ok(
    /extensions: "FxiOS\/\\\(AppInfo\.appVersion\) \\\(UserAgent\.uaBitMobile\) \\\(UserAgent\.uaBitSafari\)"/.test(src),
    'FxiOS mobile UA extension ordering changed upstream',
  );
});

test('version-scrape sources are alive and current', async (t) => {
  const body = await fetchTextOrNull(ours.sourceVersionUrl);
  if (body === null) return t.skip('network unreachable');
  const major = body.match(/^\s*(\d+)/);
  assert.ok(major, `version_display.txt unparseable: ${body.slice(0, 80)}`);
  assert.ok(
    parseInt(major[1], 10) >= ours.versionFloor,
    `scraped ${major[1]} below bundled floor ${ours.versionFloor}`,
  );
  if (parseInt(major[1], 10) > ours.versionFloor + 4) {
    console.warn(
      `[firefox_ua_upstream] kDefaultFirefoxMajorVersion=${ours.versionFloor} ` +
        `lags current release ${major[1]} — consider bumping the floor`,
    );
  }

  const details = await fetchTextOrNull(ours.productDetailsUrl);
  if (details === null) return t.skip('network unreachable');
  const latest = JSON.parse(details).LATEST_FIREFOX_VERSION;
  assert.match(latest ?? '', /^\d+\./, 'LATEST_FIREFOX_VERSION missing');
});
