// The scripts the app injects into pages, read from lib/js/ the way PageJs
// (lib/services/page_js.dart) reads them: a `// @include <file>` line becomes
// that part, and a script that reads CONFIG runs inside the same wrapper,
// with the config as JSON. test/js/page_js.test.js holds the two to the same
// rule.

const fs = require('node:fs');
const path = require('node:path');
const espree = require('espree');

const JS_DIR = path.resolve(__dirname, '..', '..', '..', 'lib', 'js');
const INCLUDE = /^[ \t]*\/\/ @include (\S+)[ \t]*$/gm;

function readJs(file) {
  return fs.readFileSync(path.join(JS_DIR, file), 'utf8');
}

// The script `lib/js/<name>.js` with its parts in place.
function pageJsSource(name) {
  return readJs(`${name}.js`).replace(INCLUDE, (_, part) => readJs(part));
}

// The script as the app injects it: as written when it reads no CONFIG,
// otherwise run with [config] bound to CONFIG.
function pageJs(name, config) {
  const source = pageJsSource(name);
  if (config === undefined) return source;
  return `(function (CONFIG) {\n${source}\n})(${JSON.stringify(config)});\n`;
}

// The functions [names] of `lib/js/<name>.js` as the script declares them,
// run with [given] bound to the names they read from the script's closure:
// a test of one piece reaches the shipped code, never a copy of it
// (SHIM-TEST-002).
function scriptFunctions(name, { names, given = {} }) {
  const source = pageJsSource(name);
  const declared = new Map();
  (function visit(node) {
    if (!node || typeof node.type !== 'string') return;
    if (node.type === 'FunctionDeclaration' && names.includes(node.id.name)) {
      declared.set(node.id.name, source.slice(node.start, node.end));
    }
    for (const value of Object.values(node)) {
      for (const child of Array.isArray(value) ? value : [value]) {
        if (child && typeof child.type === 'string') visit(child);
      }
    }
  })(espree.parse(source, { ecmaVersion: 'latest' }));
  const missing = names.filter((n) => !declared.has(n));
  if (missing.length) throw new Error(`${name}.js declares no ${missing.join(', ')}`);
  const body = `${[...declared.values()].join('\n')}\nreturn { ${names.join(', ')} };`;
  return new Function(...Object.keys(given), body)(...Object.values(given));
}

module.exports = { JS_DIR, INCLUDE, readJs, pageJsSource, pageJs, scriptFunctions };
