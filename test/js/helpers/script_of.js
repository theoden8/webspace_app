// The text of a script that calls [fn] with [args] as JSON, for code that has
// to cross into another realm as a string: a served file, a worker blob, an
// HTML page, a jsdom eval. Written as a function, it stays in reach of the
// linter (eslint.config.js). [fn] must not close over anything: only its
// source crosses.
function scriptOf(fn, ...args) {
  return `(${fn})(${args.map((a) => JSON.stringify(a)).join(', ')});\n`;
}

module.exports = { scriptOf };
