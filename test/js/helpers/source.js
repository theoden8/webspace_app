// Source access for the structural gates: one reader, one lexer, one set of
// bracket matchers, so a gate states its rule and not its plumbing.
//
// Every transform keeps offsets: `code(src)` and `code(src, {strings: true})`
// return text of the same length with the same newlines, so an index found in
// one is valid in the others and in `src`.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./dart_blocks');

const REPO = path.resolve(__dirname, '..', '..', '..');

const abs = (rel) => path.join(REPO, rel);
const exists = (rel) => fs.existsSync(abs(rel));

function read(rel) {
  assert.ok(exists(rel), `${rel} does not exist; point the gate at its new home`);
  return fs.readFileSync(abs(rel), 'utf8');
}

/** Repo-relative paths of the files under `dir` whose name matches `re`. */
function files(dir, re) {
  const out = [];
  for (const e of fs.readdirSync(abs(dir), { withFileTypes: true })) {
    const rel = `${dir}/${e.name}`;
    if (e.isDirectory()) out.push(...files(rel, re));
    else if (re.test(e.name)) out.push(rel);
  }
  return out.sort();
}

// lib/l10n/gen is gitignored gen_l10n output, present only after a build.
const dartFiles = (dir = 'lib') =>
  files(dir, /\.dart$/).filter((f) => !f.startsWith('lib/l10n/gen/'));

/**
 * `src` with comments blanked, and string literal contents too when
 * `strings` is set. Knows Dart/Kotlin/Swift/JS strings well enough that a
 * `//` inside `'https://...'` is not a comment: single, double and triple
 * quotes, Dart raw strings, escapes, nested `${...}` interpolation, nested
 * block comments. Newlines survive, so line numbers and offsets do too.
 */
function code(src, { strings = false } = {}) {
  const out = src.split('');
  const blank = (a, b) => {
    for (let k = a; k < b && k < out.length; k++) if (out[k] !== '\n') out[k] = ' ';
  };
  const stack = [];
  let i = 0;
  while (i < src.length) {
    const top = stack[stack.length - 1];
    const c = src[i];
    if (top && top.q) {
      if (!top.raw && c === '\\') {
        if (strings) blank(i, i + 2);
        i += 2;
      } else if (src.startsWith(top.q, i)) {
        stack.pop();
        i += top.q.length;
      } else if (!top.raw && c === '$' && src[i + 1] === '{') {
        stack.push({ depth: 0 });
        i += 2;
      } else if (top.q.length === 1 && c === '\n') {
        stack.pop();
        i++;
      } else {
        if (strings) blank(i, i + 1);
        i++;
      }
      continue;
    }
    if (src.startsWith('//', i)) {
      const nl = src.indexOf('\n', i);
      const end = nl === -1 ? src.length : nl;
      blank(i, end);
      i = end;
      continue;
    }
    if (src.startsWith('/*', i)) {
      let depth = 0;
      let j = i;
      while (j < src.length) {
        if (src.startsWith('/*', j)) { depth++; j += 2; }
        else if (src.startsWith('*/', j)) { j += 2; if (--depth === 0) break; }
        else j++;
      }
      blank(i, j);
      i = j;
      continue;
    }
    if (c === "'" || c === '"') {
      const raw = src[i - 1] === 'r' && !/[\w$]/.test(src[i - 2] ?? '');
      const q = src.startsWith(c.repeat(3), i) ? c.repeat(3) : c;
      stack.push({ q, raw });
      i += q.length;
      continue;
    }
    if (top) {
      if (c === '{') top.depth++;
      else if (c === '}' && top.depth-- === 0) stack.pop();
    }
    i++;
  }
  return out.join('');
}

const lineAt = (src, index) => src.slice(0, index).split('\n').length;

const CLOSER = { '{': '}', '(': ')', '[': ']' };

/**
 * The bracketed span opening at the first `opener` at or after `from`:
 * `{open, close, body}`, `body` excluding the brackets. Brackets inside
 * strings and comments do not count.
 */
function enclosed(text, from, opener = '{', what = 'source') {
  const open = text.indexOf(opener, from);
  assert.notEqual(open, -1, `no ${opener} after offset ${from} in ${what}`);
  const close = closeOf(code(text, { strings: true }), open, what);
  return { open, close, body: text.slice(open + 1, close) };
}

function closeOf(masked, open, what) {
  const opener = masked[open];
  const closer = CLOSER[opener];
  let depth = 0;
  for (let i = open; i < masked.length; i++) {
    if (masked[i] === opener) depth++;
    else if (masked[i] === closer && --depth === 0) return i;
  }
  assert.fail(`unbalanced ${opener} at offset ${open} in ${what}`);
}

/** Arguments of the call whose `(` is the first one at or after `at`. */
const callArgs = (text, at, what) => enclosed(text, at, '(', what).body;

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const KEYWORD_BEFORE = /\b(return|await|yield|throw|else|case|new|const|assert|in|is|as)\s+$/;

// After the parameter list closing at `close`: a body, or `;` behind a type.
function declKind(masked, lineStart, nameAt, close) {
  const after = masked.slice(close + 1).match(/^\s*(\{|=>|async\*?|sync\*|;)/);
  if (!after) return null;
  const before = masked.slice(lineStart, nameAt);
  const typed = /^\s*(@\w+\s+)*([\w$<>?,.[\] ]+\s+)?$/.test(before) &&
    !KEYWORD_BEFORE.test(before);
  if (!typed) return null;
  if (after[1] === ';') return /\S\s+$/.test(before) ? 'abstract' : null;
  return 'body';
}

function scan(name, { file, dir = 'lib' } = {}) {
  const bound = name.startsWith('.') ? '' : '(?<![\\w$])';
  const re = new RegExp(`${bound}${escapeRe(name)}\\s*(?:<[^()]*?>)?\\s*\\(`, 'g');
  const out = [];
  for (const rel of file ? [file] : dartFiles(dir)) {
    const src = read(rel);
    const masked = code(src, { strings: true });
    for (const m of masked.matchAll(re)) {
      const paren = m.index + m[0].length - 1;
      const close = closeOf(masked, paren, rel);
      const lineStart = masked.lastIndexOf('\n', m.index) + 1;
      out.push({ rel, src, masked, at: m.index, paren, close,
        decl: declKind(masked, lineStart, m.index, close) });
    }
  }
  return out;
}

/**
 * Every call of `name(` under `dir` (or in `file`), declarations excluded,
 * as `{file, line, index, args}`. Matches in comments and strings do not
 * count; `name` may carry a receiver (`.setProxyOverride`).
 */
function callSites(name, opts) {
  return scan(name, opts)
    .filter((s) => !s.decl)
    .map((s) => ({
      file: s.rel,
      line: lineAt(s.src, s.at),
      index: s.at,
      args: code(s.src).slice(s.paren + 1, s.close),
    }));
}

/**
 * The one declaration of method/function `name` under `dir` (or in `file`):
 * `{file, line, index, body}`, `body` being the block's inside or the `=>`
 * expression, comments blanked. Fails when there is no declaration or more
 * than one, naming each, so a gate never inspects the wrong body.
 */
function findMethod(name, opts = {}) {
  const decls = scan(name, opts).filter((s) => s.decl === 'body');
  const where = opts.file ?? opts.dir ?? 'lib';
  assert.ok(decls.length > 0, `no declaration of ${name}( in ${where}`);
  assert.equal(decls.length, 1,
    `${name}( is declared ${decls.length} times in ${where} ` +
      `(${decls.map((d) => `${d.rel}:${lineAt(d.src, d.at)}`).join(', ')}); ` +
      'pass {file} to pick one');
  const d = decls[0];
  const text = code(d.src);
  const head = d.masked.slice(d.close + 1).match(/^\s*(?:async\*?|sync\*)?\s*(\{|=>)/);
  const start = d.close + 1 + head[0].length - head[1].length;
  let body;
  if (head[1] === '{') {
    body = text.slice(start + 1, closeOf(d.masked, start, d.rel));
  } else {
    let depth = 0;
    let end = start + 2;
    for (; end < d.masked.length; end++) {
      const c = d.masked[end];
      if ('([{'.includes(c)) depth++;
      else if (')]}'.includes(c)) depth--;
      else if (c === ';' && depth === 0) break;
    }
    body = text.slice(start + 2, end);
  }
  return { file: d.rel, line: lineAt(d.src, d.at), index: d.at, body };
}

const methodBody = (name, opts) => findMethod(name, opts).body;

module.exports = {
  REPO,
  abs,
  exists,
  read,
  files,
  dartFiles,
  code,
  lineAt,
  enclosed,
  blockAfter,
  callArgs,
  callSites,
  escapeRe,
  findMethod,
  methodBody,
};
