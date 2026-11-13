// Structural gate: the Apple targets write to the system log only through
// `WebSpaceLog.line(_:carries:)` (ios/Runner/AppGroup.swift, compiled into
// both Runners and both share extensions).
//
// The system log outlives the session and other processes can read it. Each
// file once chose for itself whether a URL it logged reached release builds,
// and three chose wrong: a shortcut launch, an App Intent and both share
// extensions logged the site or the shared URL in release. A required
// `carries:` makes every line answer; a raw call does not have to, so it is
// what this refuses (rung 5: Swift has no way to forbid a Foundation call).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, exists, code, lineAt } = require('./helpers/source');

const OWNER = 'ios/Runner/AppGroup.swift';
const RAW = /\b(?:NSLog|os_log|print|debugPrint)\s*\(/g;

function swiftFiles() {
  return ['ios', 'macos']
    .filter(exists)
    .flatMap((dir) => files(dir, /\.swift$/))
    .filter((f) => !f.includes('/Pods/') && !f.includes('/.symlinks/'));
}

function rawLogs(rel, src) {
  const text = code(src, { strings: true });
  return [...text.matchAll(RAW)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('no Apple source writes to the system log except through WebSpaceLog', () => {
  const found = swiftFiles()
    .filter((rel) => rel !== OWNER)
    .flatMap((rel) => rawLogs(rel, read(rel)));
  assert.deepEqual(found, [], 'write WebSpaceLog.line(message, carries: ...) instead');
  assert.ok(read(OWNER).includes('enum WebSpaceLog'), `${OWNER} must keep WebSpaceLog`);
});

test('planted: a raw NSLog of a URL is caught, a mention in a string or comment is not', () => {
  const planted = 'NSLog("opening \\(url)")\n// NSLog(x)\nlet s = "print(x)"\n';
  assert.deepEqual(rawLogs('planted.swift', planted), ['planted.swift:1']);
});
