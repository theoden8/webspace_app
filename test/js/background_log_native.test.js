// Background log native-store gate (DEVTOOLS-012, BUG-007).
//
// The native half of the background log is a file touched from the platform
// thread (channel calls), the WorkManager coroutine / BGTaskScheduler queue
// and iOS expiration handlers. It is safe only while one serial executor owns
// every read, append, compaction and delete: a file operation that runs
// outside it races a compaction rename and loses or duplicates lines, the
// partial-synchronisation shape BUG-007 keeps finding.
//
// No Android or iOS runtime runs in these tiers, so this is structural (like
// native_bgtask_completion_funnel): every file operation must sit lexically
// inside the executor block, or in a helper only ever called from inside one.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code, enclosed, files } = require('./helpers/source');

const ktRel =
  'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/BackgroundLogFile.kt';
const swiftRel = 'ios/Runner/BackgroundTaskPlugin.swift';

// [start, end) of the brace block opening at or after `from`.
function blockAt(src, from) {
  const { open, close } = enclosed(src, from);
  return [open, close + 1];
}

function blocksAfter(src, opener) {
  const out = [];
  for (let i = src.indexOf(opener); i !== -1; i = src.indexOf(opener, i + 1)) {
    out.push(blockAt(src, i + opener.length - 1));
  }
  return out;
}

const inside = (ranges, i) => ranges.some(([a, b]) => i > a && i < b);

function offences(src, { executor, ops, helpers, skip = [] }) {
  const owned = blocksAfter(src, executor);
  assert.ok(owned.length > 0, `no ${executor} blocks found`);
  const helperBodies = helpers.map((h) => blockAt(src, src.indexOf(h.decl)));
  const out = [];
  for (const m of src.matchAll(ops)) {
    if (skip.some((s) => src.slice(m.index - 80, m.index + 1).includes(s))) continue;
    if (inside(owned, m.index) || inside(helperBodies, m.index)) continue;
    const line = src.slice(0, m.index).split('\n').length;
    out.push(`line ${line}: ${m[0]}`);
  }
  for (const h of helpers) {
    const declAt = src.indexOf(h.decl);
    for (const m of src.matchAll(h.call)) {
      if (m.index >= declAt && m.index < declAt + h.decl.length) continue;
      if (!inside(owned, m.index)) {
        out.push(`${h.decl.trim()} called outside ${executor}`);
      }
    }
  }
  return out;
}

test('Android: every file operation runs on the one executor', () => {
  const src = code(read(ktRel));
  assert.equal((src.match(/Executors\.newSingleThreadExecutor/g) || []).length, 1,
    `${ktRel} must own exactly one single-thread executor`);
  assert.ok(!/\bsynchronized\s*\(|@Volatile/.test(src),
    `${ktRel} must not mix a lock into the single-owner design`);
  assert.deepEqual(offences(src, {
    executor: 'io.execute {',
    ops: /\bFile\(|FileOutputStream\(|\.readLines\(|\.writeText\(|\.createNewFile\(|\.renameTo\(|\.delete\(\)/g,
    helpers: [{ decl: 'private fun compact(', call: /\bcompact\(/g }],
  }), []);
});

test('iOS: every file operation runs on the one serial queue', () => {
  const all = code(read(swiftRel));
  const start = all.indexOf('final class BackgroundLogFile');
  assert.notEqual(start, -1, `${swiftRel} must define BackgroundLogFile`);
  const [a, b] = blockAt(all, start);
  const src = all.slice(a, b);
  assert.equal((src.match(/DispatchQueue\(label:/g) || []).length, 1,
    'BackgroundLogFile must own exactly one serial queue');
  assert.deepEqual(offences(src, {
    executor: 'queue.async {',
    ops: /FileManager\.default|FileHandle\(|String\(contentsOf:|\.write\(to:|\.removeItem\(|\.createFile\(/g,
    helpers: [{ decl: 'private static func compact(', call: /\.compact\(/g }],
    // The path is computed once at init; nothing touches the file there.
    skip: ['private let url: URL? ='],
  }), []);
});

test('only the background-log owners name the file', () => {
  // A second writer elsewhere would be outside the executor by construction.
  const owners = new Set([ktRel, swiftRel]);
  const hits = ['android/app/src', 'ios/Runner', 'macos/Runner', 'lib']
    .flatMap((root) => files(root, /\.(kt|swift|dart)$/))
    .filter((f) => read(f).includes('background_log.jsonl') && !owners.has(f));
  assert.deepEqual(hits, []);
});

test('the native file takes only what Dart appends and its own lines', () => {
  // Sensitive separation: the native side has no site data, so the only way a
  // site name could reach the file is a native record() fed from a channel
  // argument. The single channel path in is appendBackgroundLog.
  for (const rel of [
    'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/BackgroundTaskAndroidPlugin.kt',
    'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/NotificationRefreshWorker.kt',
    swiftRel,
    'ios/Runner/AppDelegate.swift',
  ]) {
    const src = code(read(rel));
    for (const m of src.matchAll(/BackgroundLogFile(?:\.shared)?\.record\(([\s\S]*?)\)\s*\n/g)) {
      assert.ok(!/call\.arguments|args\[|args\?\./.test(m[1]),
        `${rel}: a native record() is fed from a channel argument: ${m[1].trim()}`);
    }
  }
});

test('iOS: the grace-period launch note reads markers the code still writes', () => {
  // The note at launch is inferred from the last line about the grace window,
  // matched by message prefix. A reworded message would leave the inference
  // looking for a line nobody writes, and the note would silently stop.
  const swift = read(swiftRel);
  const fn = swift.indexOf('private static func endedInGrace(');
  assert.notEqual(fn, -1, `${swiftRel} must define endedInGrace`);
  const body = swift.slice(fn, swift.indexOf('\n  }\n', fn));
  const prefixes = [...body.matchAll(/hasPrefix\("([^"]+)"\)/g)].map((m) => m[1]);
  assert.deepEqual([...prefixes].sort(), [
    'App resumed', 'grace period', 'grace period started',
    'process launched', 'process terminating',
  ].sort());
  const writers = [swiftRel, 'ios/Runner/AppDelegate.swift',
    'lib/controllers/app_lifecycle_controller.dart'].map(read).join('\n');
  for (const p of prefixes) {
    assert.ok(new RegExp(`["']${p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).test(writers),
      `nothing writes a line starting "${p}" any more; update endedInGrace`);
  }
  assert.match(read('ios/Runner/AppDelegate.swift'), /BackgroundLogFile\.shared\.recordLaunch\(/,
    'the launch line must go through recordLaunch, which writes the note first');
});
