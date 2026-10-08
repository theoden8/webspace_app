// The gates trust test/js/helpers/source.js to find the code they judge; a
// lexer that misreads a URL as a comment, or a matcher that picks the wrong
// body, turns every gate built on it into a false pass.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const src = require('./helpers/source');

const { code, enclosed, callArgs, lineAt } = src;

test('code keeps offsets and newlines', () => {
  const text = "a /* x\ny */ b // z\nc";
  const out = code(text);
  assert.equal(out.length, text.length);
  assert.equal(out, 'a     \n     b     \nc');
});

test('code leaves comment markers inside strings alone', () => {
  const text = "f('https://x/*y*/'); // gone\ng(\"a//b\");";
  assert.equal(code(text), "f('https://x/*y*/');        \ng(\"a//b\");");
});

test('code with strings blanks literal contents but not interpolated code', () => {
  assert.equal(code("x('a{b', \"c\");", { strings: true }), "x('   ', \" \");");
  assert.equal(code("'\\'{'", { strings: true }), "'   '");
  assert.equal(code("'p${m({1: 2})}q'", { strings: true }), "' ${m({1: 2})} '");
  assert.equal(code("r'\\'", { strings: true }), "r' '");
  assert.equal(code("'''a\n'b'\n''' c", { strings: true }), "''' \n   \n''' c");
});

test('code nests block comments and survives an unterminated string line', () => {
  assert.equal(code('a /* 1 /* 2 */ 3 */ b'), 'a                   b');
  assert.equal(code("x = 'oops\ny = 1;", { strings: true }), "x = '    \ny = 1;");
});

test('enclosed matches one bracket kind, ignoring strings and comments', () => {
  const text = "m(a, '(', [b]) { if (c) { d('}'); } // }\n}";
  assert.equal(callArgs(text, 0), "a, '(', [b]");
  assert.equal(enclosed(text, 0).body, " if (c) { d('}'); } // }\n");
  assert.throws(() => enclosed('f(', 0, '('), /unbalanced/);
  assert.throws(() => enclosed('f', 0, '('), /no \(/);
});

test('lineAt is 1-based', () => {
  assert.equal(lineAt('a\nb\nc', 0), 1);
  assert.equal(lineAt('a\nb\nc', 4), 3);
});

function withLib(filesByName, fn) {
  const rel = path.relative(src.REPO, fs.mkdtempSync(path.join(src.REPO, 'build', 'srchelper-')));
  try {
    for (const [name, text] of Object.entries(filesByName)) {
      fs.writeFileSync(path.join(src.REPO, rel, name), text);
    }
    return fn(rel);
  } finally {
    fs.rmSync(path.join(src.REPO, rel), { recursive: true, force: true });
  }
}

fs.mkdirSync(path.join(src.REPO, 'build'), { recursive: true });

const SERVICE = `
class S {
  Future<bool> isBlocked(String url, {String? sourceUrl}) async {
    // isBlocked(fake) in a comment
    return engine.check(stripRootDot(url), sourceUrl: '{');
  }

  static Set<int> unload({required bool global}) => {for (final i in xs) i};

  void caller() {
    final a = isBlocked('x');
    if (isBlocked(y, sourceUrl: z)) {}
    log('isBlocked(not a call)');
    svc.isBlocked(q);
  }

  Future<void> abstractOne(int x);
}
`;

test('findMethod returns the one declaration, body without comments', () => {
  withLib({ 'a.dart': SERVICE }, (dir) => {
    const m = src.findMethod('isBlocked', { dir });
    assert.equal(m.file, `${dir}/a.dart`);
    assert.equal(m.line, 3);
    assert.match(m.body, /stripRootDot\(url\)/);
    assert.doesNotMatch(m.body, /fake/);
    assert.match(src.methodBody('unload', { dir }), /^ \{for \(final i in xs\) i\}$/);
  });
});

test('findMethod fails loudly on zero or several declarations', () => {
  withLib({ 'a.dart': SERVICE, 'b.dart': 'bool isBlocked(u) { return true; }\n' }, (dir) => {
    assert.throws(() => src.methodBody('isBlocked', { dir }), /declared 2 times.*a\.dart:3.*b\.dart:1/);
    assert.equal(src.methodBody('isBlocked', { file: `${dir}/b.dart` }), ' return true; ');
    assert.throws(() => src.methodBody('missing', { dir }), /no declaration of missing\(/);
    assert.throws(() => src.methodBody('abstractOne', { dir }), /no declaration/);
  });
});

test('callSites skips declarations, comments and strings', () => {
  withLib({ 'a.dart': SERVICE }, (dir) => {
    const calls = src.callSites('isBlocked', { dir });
    assert.deepEqual(calls.map((c) => [c.line, c.args]), [
      [11, "'x'"],
      [12, 'y, sourceUrl: z'],
      [14, 'q'],
    ]);
    assert.deepEqual(src.callSites('abstractOne', { dir }), []);
    assert.equal(src.callSites('.check', { dir })[0].args, "stripRootDot(url), sourceUrl: '{'");
  });
});

test('files lists recursively, repo-relative and sorted; read fails on a missing file', () => {
  const listed = src.dartFiles('lib/services');
  assert.ok(listed.includes('lib/services/site_lifecycle_engine.dart'));
  assert.deepEqual(listed, [...listed].sort());
  assert.throws(() => src.read('lib/no_such_file.dart'), /does not exist/);
});
