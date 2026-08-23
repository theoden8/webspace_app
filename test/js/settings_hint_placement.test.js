// HINT-002: a settings row's subtitle is a caption, not a paragraph.
//
// A `subtitle:` whose text is a fixed localized string is a description of the
// setting, and it is the one string on the row nobody budgets for: English
// reads as one tidy line, then Greek, Malay or Malayalam runs to three or four
// and the list turns ragged. Nothing overflows, so no render test sees it.
//
// The fix is never to shorten the translation - it is to move the explanation
// into the row's HintButton, where length costs nothing. This gate draws the
// line at two lines' worth of text in the worst locale we ship.
//
// Subtitles built from state (a value, a count, "Not configured", a branch on
// the setting) are exempt: they are what a subtitle is for, and they are
// already short because the state they name is short.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const scanRoots = ['lib/main.dart', 'lib/screens', 'lib/widgets'];
const arbDir = path.join(repoRoot, 'lib', 'l10n');

// Roughly two lines under a switch on a 360dp phone. A proxy for width, not a
// measurement of it: scripts differ, and the point is to catch the paragraph,
// not to police the last character.
const SUBTITLE_BUDGET = 90;

function discoverDartFiles(roots) {
  const out = [];
  const walk = (abs, rel) => {
    for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
      const childAbs = path.join(abs, e.name);
      const childRel = `${rel}/${e.name}`;
      if (e.isDirectory()) walk(childAbs, childRel);
      else if (e.isFile() && e.name.endsWith('.dart')) out.push(childRel);
    }
  };
  for (const root of roots) {
    const abs = path.join(repoRoot, root);
    if (!fs.existsSync(abs)) continue;
    if (fs.statSync(abs).isDirectory()) walk(abs, root);
    else if (root.endsWith('.dart')) out.push(root);
  }
  return out;
}

// The argument to `subtitle:`, read to the comma that closes it. Tracks
// bracket depth and steps over string literals so a comma inside either one
// does not end the expression early.
function readArgument(source, from) {
  let i = from;
  while (i < source.length && /\s/.test(source[i])) i += 1;
  const start = i;
  let depth = 0;
  for (; i < source.length; i += 1) {
    const c = source[i];
    if ('([{'.includes(c)) depth += 1;
    else if (')]}'.includes(c)) {
      if (depth === 0) break;
      depth -= 1;
    } else if (c === ',' && depth === 0) break;
    else if (c === "'" || c === '"') {
      const quote = c;
      i += 1;
      while (i < source.length && source[i] !== quote) {
        if (source[i] === '\\') i += 1;
        i += 1;
      }
    }
  }
  return source.slice(start, i);
}

// A subtitle expression names one fixed string and nothing else: exactly one
// `loc.key`, none of them invoked with placeholders, and no branch choosing
// between alternatives.
function staticKeyOf(expr) {
  const refs = [...expr.matchAll(/\bloc\.([A-Za-z0-9_]+)\s*(\()?/g)];
  if (refs.length !== 1) return null;
  if (refs[0][2]) return null;
  if (expr.includes('?') || /\bswitch\b/.test(expr)) return null;
  return refs[0][1];
}

function collectStaticSubtitles() {
  const found = [];
  for (const rel of discoverDartFiles(scanRoots)) {
    const source = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    for (const m of source.matchAll(/\bsubtitle:/g)) {
      const key = staticKeyOf(readArgument(source, m.index + 'subtitle:'.length));
      if (!key) continue;
      const line = (source.slice(0, m.index).match(/\n/g) || []).length + 1;
      found.push({ key, rel, line });
    }
  }
  return found;
}

const locales = fs
  .readdirSync(arbDir)
  .filter((f) => f.startsWith('app_') && f.endsWith('.arb'))
  .map((f) => ({ name: f.slice(4, -4), arb: JSON.parse(fs.readFileSync(path.join(arbDir, f), 'utf8')) }));

test('extraction still finds the settings subtitles it is meant to police', () => {
  const found = collectStaticSubtitles();
  assert.ok(
    found.length > 10,
    `expected the scan to find many fixed-string subtitles, found ${found.length} - did the extractor break?`,
  );
  assert.ok(locales.length > 10, `expected many locales, found ${locales.length}`);
});

test('a fixed-string subtitle fits the row in every locale', () => {
  const violations = [];
  for (const { key, rel, line } of collectStaticSubtitles()) {
    let worst = null;
    for (const { name, arb } of locales) {
      const value = arb[key];
      if (typeof value !== 'string') continue;
      if (!worst || value.length > worst.length) worst = { name, length: value.length };
    }
    if (worst && worst.length > SUBTITLE_BUDGET) {
      violations.push(
        `  ${rel}:${line}: ${key} is ${worst.length} chars in ${worst.name} `
          + `(budget ${SUBTITLE_BUDGET})`,
      );
    }
  }
  assert.deepEqual(
    violations,
    [],
    'These subtitles explain the setting rather than report its state, and are too long '
      + 'to sit on the row in every language. Move each into a HintButton on the title row '
      + `and drop the subtitle:\n${violations.join('\n')}`,
  );
});
