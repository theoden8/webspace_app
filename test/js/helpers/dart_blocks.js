// Brace-matching over Dart source, for the structural gates that assert where
// a statement sits inside a method rather than merely that it exists.

const assert = require('node:assert/strict');

/**
 * Body of the brace-balanced block that opens at the first `{` at or after
 * `marker` — or after `openAt`, searched from `marker`, when given. A marker
 * that ends in `(` opens a signature, so its parameter list is skipped first:
 * named parameters have a `{` of their own before the body.
 */
function blockAfter(text, marker, openAt, what = 'source') {
  const at = text.indexOf(marker);
  assert.notEqual(at, -1, `${what} no longer contains ${marker}`);
  let from = openAt ? text.indexOf(openAt, at) : at + marker.length - 1;
  assert.notEqual(from, -1, `${what} no longer contains ${openAt}`);
  if (!openAt && marker.endsWith('(')) from = closingParen(text, from, marker);
  const open = text.indexOf('{', from);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) return text.slice(open + 1, i);
  }
  assert.fail(`unbalanced braces after ${marker} in ${what}`);
}

function closingParen(text, open, marker) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '(') depth++;
    else if (text[i] === ')' && --depth === 0) return i;
  }
  assert.fail(`unbalanced parentheses after ${marker}`);
}

module.exports = { blockAfter };
