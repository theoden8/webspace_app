// BUG-007 class gate: Android native state another thread can observe.
//
// Every BUG-007 instance on Android was a mutable collection read on chromium's
// sub-resource IO threads beside a write from the main thread, with half of the
// accesses locked: a writer-only @Synchronized, a lock that missed the size
// check, a synchronized wrapper whose compound get-then-put was not atomic.
// Two shapes are correct, and this gate admits only those:
//
// - Guarded<T> (or SiteEventInbox, built on it): the state is reachable only
//   inside one monitor, so no access can skip the lock.
// - An immutable snapshot behind a @Volatile var, replaced whole by one writer.
//
// Anything else that holds a mutable collection in a property, or takes a raw
// monitor, has to be named below with the reason it is safe, so the next one
// is a deliberate edit to this file rather than a silent recurrence.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, code, lineAt } = require('./helpers/source');

const ROOT = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace';
const kotlin = [...files('android/app/src/main', /\.kt$/), ...files('android/app/src/debug', /\.kt$/)];

// Properties holding a bare mutable collection that only one thread touches.
const CONFINED = {
  [`${ROOT}/WebInterceptPlugin.kt`]: {
    siteIdMap: 'read and written only by attachToAllWebViews, on the main thread',
    siteDnsLevel: 'read and written only by attachToAllWebViews, on the main thread',
    siteLocalCdn: 'read and written only by attachToAllWebViews, on the main thread',
  },
  [`${ROOT}/CapturePermissionPlugin.kt`]: {
    pending: 'method calls and onRequestPermissionsResult both arrive on the main thread',
  },
};

// Files that take a lock directly rather than through Guarded.
const LOCKS = {
  [`${ROOT}/Guarded.kt`]: 'the monitor every Guarded access goes through',
  [`${ROOT}/DnsHostBlocklist.kt`]:
    'wait/notify for the fail-closed build wait, which Guarded cannot express',
  [`${ROOT}/AdblockEngineNative.kt`]:
    'read/write lock: concurrent readers on the IO hot path, exclusive free (attempt 1)',
  [`${ROOT}/proxy/ProxyRelay.kt`]:
    'serialises writers; accept threads read @Volatile immutable snapshots',
};

const LOCK = /\bsynchronized\s*\(|@Synchronized\b|\b(?:Reentrant(?:ReadWrite)?Lock|StampedLock)\b/;
const HALF_SAFE = /\bCollections\.synchronized\w*|\b(?:Concurrent(?:HashMap|LinkedQueue|LinkedDeque|SkipList\w*)|CopyOnWrite\w*)\b/;
const MUTABLE_TYPE = new RegExp('\\b(?:Mutable(?:List|Map|Set|Collection|Iterable)|(?:Linked)?Hash(?:Map|Set)' +
  '|ArrayList|ArrayDeque|LinkedList|Tree(?:Map|Set)|EnumMap|WeakHashMap|IdentityHashMap)\\b');
const MUTABLE_INIT = new RegExp('^(?:java\\.util\\.)?(?:mutable(?:List|Map|Set)Of|hashMapOf|hashSetOf' +
  '|linkedMapOf|linkedSetOf|arrayListOf|(?:Linked)?Hash(?:Map|Set)|ArrayList|ArrayDeque|LinkedList' +
  '|Tree(?:Map|Set)|EnumMap|WeakHashMap|IdentityHashMap)\\b');
const READONLY_TYPE = /^(?:List|Map|Set|Collection|Iterable)\s*</;
const READONLY_INIT = /^(?:emptyList|emptyMap|emptySet|listOf|mapOf|setOf|listOfNotNull)\b/;
const GUARDED = /^Guarded\s*[<(]/;

/** End of a class header at `from`: the body's `{`, or -1 when it has none. */
function bodyOpen(masked, from) {
  let depth = 0;
  for (let i = from; i < masked.length; i++) {
    const c = masked[i];
    if (c === '(' || c === '<') depth++;
    else if (c === ')' || (c === '>' && masked[i - 1] !== '-')) depth--;
    else if (depth === 0 && c === '{') return i;
    else if (depth === 0 && c === '\n') {
      const rest = masked.slice(i).match(/^\s*(\S)/);
      const line = masked.slice(masked.lastIndexOf('\n', i - 1) + 1, i).trimEnd();
      if (!rest || (!':{,'.includes(rest[1]) && !/[:,]$/.test(line))) return -1;
    }
  }
  return -1;
}

function closeBrace(masked, open) {
  let depth = 0;
  for (let i = open; i < masked.length; i++) {
    if (masked[i] === '{') depth++;
    else if (masked[i] === '}' && --depth === 0) return i;
  }
  return masked.length;
}

/** `[start, end)` spans whose top level holds member declarations. */
function memberScopes(masked) {
  const scopes = [{ start: 0, end: masked.length, ctor: false }];
  for (const m of masked.matchAll(/\b(?:class|object|interface)\b/g)) {
    const paren = masked.slice(m.index).search(/[({\n]/);
    if (paren >= 0 && masked[m.index + paren] === '(') {
      const open = m.index + paren;
      let depth = 0;
      let i = open;
      for (; i < masked.length; i++) {
        if (masked[i] === '(') depth++;
        else if (masked[i] === ')' && --depth === 0) break;
      }
      scopes.push({ start: open + 1, end: i, ctor: true });
    }
    const open = bodyOpen(masked, m.index);
    if (open >= 0) scopes.push({ start: open + 1, end: closeBrace(masked, open), ctor: false });
  }
  return scopes;
}

/** Every member property: `{name, mutable, annotations, type, init, line}`. */
function properties(rel) {
  const src = read(rel);
  const masked = code(src, { strings: true });
  const out = [];
  for (const scope of memberScopes(masked)) {
    let depth = 0;
    let parens = 0;
    let param = scope.start;
    for (let i = scope.start; i < scope.end; i++) {
      const c = masked[i];
      if (c === '{') depth++;
      else if (c === '}') depth--;
      else if (c === '(') parens++;
      else if (c === ')') parens--;
      else if (scope.ctor && c === ',' && depth === 0 && parens === 0) param = i + 1;
      if (depth !== 0 || parens !== 0) continue;
      if (!/\b(?:val|var)\b/.test(masked.slice(i, i + 4)) || /[\w$]/.test(masked[i - 1] ?? '')) continue;
      const lineStart = masked.lastIndexOf('\n', i - 1) + 1;
      const head = masked.slice(Math.max(lineStart, param), i);
      if (!/^[\s(,]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|protected|internal|public|override|open|lateinit|const|final)\s+)*$/.test(head)) continue;
      const end = scope.ctor
        ? (() => { let d = 0; let j = i; for (; j < scope.end; j++) {
          if ('(<['.includes(masked[j])) d++;
          else if (')>]'.includes(masked[j]) && masked[j - 1] !== '-') d--;
          else if (d === 0 && masked[j] === ',') break;
        } return j; })()
        : (() => { const nl = masked.indexOf('\n', i); return nl === -1 ? scope.end : nl; })();
      const decl = masked.slice(i, end);
      const m = decl.match(/^(val|var)\s+(\w+)\s*(?::\s*([^=]+?))?\s*(?:=\s*([\s\S]*))?$/);
      if (!m) continue;
      const above = [];
      for (let k = lineStart - 1; k > 0;) {
        const prev = masked.lastIndexOf('\n', k - 1) + 1;
        const text = masked.slice(prev, k).trim();
        if (/^@\w+/.test(text)) above.push(text);
        else if (text !== '') break;
        k = prev - 1;
      }
      out.push({
        name: m[2],
        mutable: m[1] === 'var',
        annotations: `${above.join(' ')} ${head}`,
        type: (m[3] ?? '').trim(),
        init: (m[4] ?? '').trim(),
        line: lineAt(src, i),
      });
    }
  }
  return out;
}

const bareMutable = (p) =>
  !GUARDED.test(p.type) && !GUARDED.test(p.init) &&
  (MUTABLE_TYPE.test(p.type) || MUTABLE_INIT.test(p.init));

const unpublishedSnapshot = (p) =>
  p.mutable && !/@Volatile\b/.test(p.annotations) &&
  (READONLY_TYPE.test(p.type) || (!p.type && READONLY_INIT.test(p.init)));

test('the Kotlin sources and the guard types are found', () => {
  assert.ok(kotlin.includes(`${ROOT}/WebInterceptPlugin.kt`));
  assert.match(read(`${ROOT}/Guarded.kt`), /class Guarded<T : Any>\(private val state: T\)/,
    'Guarded must keep its state private, or the monitor stops being the only way in');
  assert.match(read(`${ROOT}/SiteEventInbox.kt`), /private val batches = Guarded\(/);
});

test('no collection that is made safe one call at a time', () => {
  // A synchronized wrapper or a concurrent map locks each call, not the
  // get-then-put around it; the inbox this replaced paired one with a
  // separately locked inner map.
  const hits = kotlin.flatMap((rel) => {
    const masked = code(read(rel), { strings: true });
    return [...masked.matchAll(new RegExp(HALF_SAFE.source, 'g'))]
      .map((m) => `${rel}:${lineAt(masked, m.index)} ${m[0]}`);
  });
  assert.deepEqual(hits, [], 'use Guarded (or SiteEventInbox) instead');
});

test('no property holds a bare mutable collection unless it is confined', () => {
  const hits = kotlin.flatMap((rel) => properties(rel)
    .filter((p) => bareMutable(p) && !CONFINED[rel]?.[p.name])
    .map((p) => `${rel}:${p.line} ${p.name}`));
  assert.deepEqual(hits, [],
    'wrap it in Guarded, publish an immutable snapshot through a @Volatile var, ' +
    'or name it in CONFINED with the one thread that touches it');
});

test('a swapped collection is published through @Volatile', () => {
  const hits = kotlin.flatMap((rel) => properties(rel)
    .filter((p) => unpublishedSnapshot(p) && !CONFINED[rel]?.[p.name])
    .map((p) => `${rel}:${p.line} ${p.name}`));
  assert.deepEqual(hits, [], 'an IO thread may never see a replacement written without it');
});

test('raw locks appear only where Guarded cannot serve', () => {
  const hits = kotlin.filter((rel) => LOCK.test(code(read(rel), { strings: true })) && !LOCKS[rel]);
  assert.deepEqual(hits, [], 'go through Guarded, or name the file in LOCKS with why it cannot');
});

test('every exemption still names something', () => {
  for (const [rel, names] of Object.entries(CONFINED)) {
    const found = new Set(properties(rel).filter(bareMutable).map((p) => p.name));
    for (const name of Object.keys(names)) {
      assert.ok(found.has(name), `${rel} no longer holds ${name}; drop it from CONFINED`);
    }
  }
  for (const rel of Object.keys(LOCKS)) {
    assert.ok(LOCK.test(code(read(rel), { strings: true })), `${rel} takes no lock; drop it from LOCKS`);
  }
});
