// Tracking-protection umbrella funnel gate (ETP-024 and the four forced-on
// subordinates). The umbrella is only as strong as the weakest path that
// reaches a webview: a new call site that passes the *stored* value of a
// forced setting silently reopens the hole the umbrella exists to close, and
// nothing at runtime says so. Third-party cookies are the reason this gate
// exists: they sat outside the umbrella through several releases while it
// forced the four list-based blockers on.
//
// The rule: anywhere under lib/ that hands a per-site posture to a webview,
// a forced setting must be spelled as its forcing expression, never as the
// raw stored field.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

// Every file that builds a WebViewConfig or forwards posture to one.
const CARRIERS = [
  'lib/web_view_model.dart',
  'lib/screens/inappbrowser.dart',
  'lib/main.dart',
];

// Forced ON while the umbrella is on: the stored value may only widen, never
// narrow, what the umbrella already guarantees.
const FORCED_ON = [
  'clearUrlEnabled',
  'dnsBlockEnabled',
  'contentBlockEnabled',
  'localCdnEnabled',
];

// Forced OFF while the umbrella is on. The one subordinate that inverts:
// third-party cookies are the oldest cross-site tracking channel, so the
// umbrella must be able to take them away, not just add blockers.
const FORCED_OFF = 'thirdPartyCookiesEnabled';

// Argument values accepted for a forced-off setting.
const FORCED_OFF_OK = [
  // The model's effective getter.
  /^\s*(?:\w+\.)?effectiveThirdPartyCookiesEnabled\s*$/,
  // An inline conjunction with the umbrella negated, for the nested screen,
  // which has no model to ask.
  /!\s*(?:widget\.)?trackingProtectionEnabled/,
  // Deserialization: reading the stored value back is not a call site.
  /^\s*json\[/,
];

// `launchUrl` in main.dart forwards its own same-named parameter onward; the
// caller resolved the value already, so that one hop is not a raw read.
// Everywhere else the bare identifier is the stored field.
const bareForward = (rel, value) =>
  rel === 'lib/main.dart'
  && new RegExp(`^\\s*${FORCED_OFF}\\s*$`).test(value);

// Every `name: <value>` argument in `src`, with the value read to the comma
// that closes it at argument depth. Comments and strings are skipped so a
// `//` note or a `,` inside a literal cannot end an argument early.
function namedArgs(src, name) {
  const out = [];
  const needle = new RegExp(`(?<![\\w.])${name}\\s*:`, 'g');
  let m;
  while ((m = needle.exec(src)) !== null) {
    let i = m.index + m[0].length;
    let depth = 0;
    let value = '';
    let quote = null;
    while (i < src.length) {
      const c = src[i];
      if (quote) {
        if (c === '\\') { value += src.slice(i, i + 2); i += 2; continue; }
        if (c === quote) quote = null;
      } else if (c === "'" || c === '"') {
        quote = c;
      } else if (c === '/' && src[i + 1] === '/') {
        i = src.indexOf('\n', i);
        if (i < 0) break;
        continue;
      } else if ('([{<'.includes(c)) {
        depth++;
      } else if (')]}>'.includes(c)) {
        if (depth === 0) break;
        depth--;
      } else if (c === ',' && depth === 0) {
        break;
      }
      value += c;
      i++;
    }
    out.push(value);
  }
  return out;
}

test('the funnel test can actually see arguments (self-check)', () => {
  // Guards against the parser silently matching nothing, which would make
  // every assertion below vacuously true.
  const src = read('lib/screens/inappbrowser.dart');
  assert.ok(
    namedArgs(src, FORCED_OFF).length > 0,
    `no ${FORCED_OFF}: arguments found; the parser is broken, not the code`,
  );
});

test('the model exposes an effective getter for the forced-off setting', () => {
  const src = read('lib/web_view_model.dart');
  assert.match(
    src,
    /bool get effectiveThirdPartyCookiesEnabled\s*=>\s*\n?\s*trackingProtectionEnabled \? false : thirdPartyCookiesEnabled;/,
    'WebViewModel must derive third-party cookies from the umbrella',
  );
  // Stored separately from effective, so turning the umbrella off restores
  // the user's own choice instead of resetting it.
  assert.match(src, /bool thirdPartyCookiesEnabled;/);
  assert.match(src, /'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,/);
});

for (const rel of CARRIERS) {
  const src = read(rel);

  test(`${rel}: forced-off setting never passes its stored value`, () => {
    for (const value of namedArgs(src, FORCED_OFF)) {
      const collapsed = value.replace(/\s+/g, ' ').trim();
      // Declarations and the model's own storage are not call sites.
      if (/^(bool|final|this\.)/.test(collapsed) || collapsed === '') continue;
      if (bareForward(rel, value)) continue;
      assert.ok(
        FORCED_OFF_OK.some((re) => re.test(value)),
        `${rel}: ${FORCED_OFF} passed as "${collapsed}". It must go through `
          + 'effectiveThirdPartyCookiesEnabled, or negate the umbrella inline.',
      );
    }
  });

  test(`${rel}: forced-on settings keep the umbrella term`, () => {
    for (const name of FORCED_ON) {
      for (const value of namedArgs(src, name)) {
        const collapsed = value.replace(/\s+/g, ' ').trim();
        if (/^(bool|final|this\.)/.test(collapsed) || collapsed === '') continue;
        // A bare field forward inside main.dart's launchUrl signature is
        // fine: inappbrowser.dart applies the umbrella at the config it
        // builds, which its own case above covers.
        if (rel !== 'lib/screens/inappbrowser.dart') continue;
        assert.match(
          value,
          /\|\|\s*(?:widget\.)?trackingProtectionEnabled/,
          `${rel}: ${name} passed as "${collapsed}" without the umbrella term.`,
        );
      }
    }
  });
}
