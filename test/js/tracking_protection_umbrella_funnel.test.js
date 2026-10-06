// Tracking-protection umbrella funnel gate (ETP-024).
//
// Every surface that runs as a site is built from one SitePosture, which
// WebViewModel.sitePosture resolves with the umbrella applied, so the compiler
// and test/site_posture_test.dart hold the forced settings there. What is left
// is the one place the model re-applies settings to a live controller
// (setController), which reads the model rather than a posture: third-party
// cookies there must go through the effective getter, never the stored field.
// They are the reason this gate exists: they sat outside the umbrella through
// several releases while it forced the four list-based blockers on.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

// Forced OFF while the umbrella is on. The one subordinate that inverts:
// third-party cookies are the oldest cross-site tracking channel, so the
// umbrella must be able to take them away, not just add blockers.
const FORCED_OFF = 'thirdPartyCookiesEnabled';

// Argument values accepted for a forced-off setting.
const FORCED_OFF_OK = [
  // The model's effective getter.
  /^\s*(?:\w+\.)?effectiveThirdPartyCookiesEnabled\s*$/,
  // Deserialization: reading the stored value back is not a call site.
  /^\s*json\[/,
  // The same read through `WebViewModel.fromJson`'s tolerant field reader.
  /^\s*field<bool>\(\s*'thirdPartyCookiesEnabled'\s*\)/,
];

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

const MODEL = 'lib/web_view_model.dart';

test('the funnel test can actually see arguments (self-check)', () => {
  // Guards against the parser silently matching nothing, which would make
  // every assertion below vacuously true.
  assert.ok(
    namedArgs(read(MODEL), FORCED_OFF).length > 0,
    `no ${FORCED_OFF}: arguments found; the parser is broken, not the code`,
  );
});

test('the model exposes an effective getter for the forced-off setting', () => {
  const src = read(MODEL);
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

test(`${MODEL}: forced-off setting never passes its stored value`, () => {
  for (const value of namedArgs(read(MODEL), FORCED_OFF)) {
    const collapsed = value.replace(/\s+/g, ' ').trim();
    // Declarations and the model's own storage are not call sites.
    if (/^(bool|final|this\.)/.test(collapsed) || collapsed === '') continue;
    assert.ok(
      FORCED_OFF_OK.some((re) => re.test(value)),
      `${MODEL}: ${FORCED_OFF} passed as "${collapsed}". It must go through `
        + 'effectiveThirdPartyCookiesEnabled.',
    );
  }
});
