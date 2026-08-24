// Brace-matching over Dart source, for the structural gates that assert where
// a statement sits inside a method rather than merely that it exists.

const assert = require('node:assert/strict');

/**
 * Body of the brace-balanced block that opens at the first `{` at or after
 * `marker` — or after `openAt`, searched from `marker`, when given: a Dart
 * signature with named parameters has a `{` of its own before the body.
 */
function blockAfter(text, marker, openAt, what = 'source') {
  const at = text.indexOf(marker);
  assert.notEqual(at, -1, `${what} no longer contains ${marker}`);
  const from = openAt ? text.indexOf(openAt, at) : at + marker.length - 1;
  assert.notEqual(from, -1, `${what} no longer contains ${openAt}`);
  const open = text.indexOf('{', from);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) return text.slice(open + 1, i);
  }
  assert.fail(`unbalanced braces after ${marker} in ${what}`);
}

module.exports = { blockAfter };
