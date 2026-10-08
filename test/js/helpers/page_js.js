// The scripts the app injects into pages, read from lib/js/ the way PageJs
// (lib/services/page_js.dart) reads them: a `// @include <file>` line becomes
// that part, and a script that reads CONFIG runs inside the same wrapper,
// with the config as JSON. test/js/page_js.test.js holds the two to the same
// rule.

const fs = require('node:fs');
const path = require('node:path');

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

module.exports = { JS_DIR, INCLUDE, readJs, pageJsSource, pageJs };
