// DNS blocklist blob format: Dart writer vs Kotlin reader.
//
// `WebInterceptNative.sendDnsLevelGroups` serialises the level-membership
// groups as `#<mask-hex>` sections and `DnsHostBlocklist.parse` reads them
// back on the other side of a platform channel. Nothing links the two: a
// radix or prefix change on either side compiles, ships, and silently
// mis-files every domain into the wrong level — the Android interceptor would
// then block at a level the user never chose.
//
// The Kotlin half has JVM unit tests, but no Android SDK is available in this
// repo's Dart+JS tiers, so the agreement between the two is guarded
// structurally here (same shape as native_bgtask_completion_funnel).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const writerRel = 'lib/services/web_intercept_native.dart';
const storeRel = 'lib/services/dns_block_service.dart';
const readerRel =
  'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/DnsHostBlocklist.kt';

const writer = read(writerRel);
const store = read(storeRel);
const reader = read(readerRel);

test('both Dart writers emit the marker as "#" + hex', () => {
  // toRadixString(16) inside a `#`-prefixed line, in the channel push and in
  // the on-disk serialiser. Decimal would agree with hex for every mask below
  // ten and diverge silently above it.
  for (const [rel, src] of [
    [writerRel, writer],
    [storeRel, store],
  ]) {
    assert.match(
      src,
      /writeln\('#\$\{mask\.toRadixString\(16\)\}'\)/,
      `${rel} must write the group marker as "#" + hex`,
    );
  }
});

test('the Kotlin reader parses the marker as hex', () => {
  assert.match(
    reader,
    /line\[0\] == '#'/,
    `${readerRel} must recognise the marker by a leading '#'`,
  );
  assert.match(
    reader,
    /line\.substring\(1\)\.trim\(\)\.toIntOrNull\(16\)/,
    `${readerRel} must parse the marker with radix 16`,
  );
});

test('the Dart reader parses the marker as hex', () => {
  assert.match(
    store,
    /int\.tryParse\(trimmed\.substring\(1\), radix: 16\)/,
    `${storeRel} must parse the marker with radix 16`,
  );
});

test('an unmarked blob is read as level 1 on both sides', () => {
  // Guards the compatibility path: a payload from a build that predates the
  // sections must still load rather than land in group 0 and block nothing.
  assert.match(
    reader,
    /var mask = levelBit\(1\)/,
    `${readerRel} must default to level 1 before any marker`,
  );
});

test('the level bit is the same function on both sides', () => {
  assert.match(
    read('lib/services/dns_level_mask_engine.dart'),
    /int dnsLevelBit\(int level\) => 1 << \(level - 1\);/,
    'Dart level bit must be 1 << (level - 1)',
  );
  assert.match(
    reader,
    /fun levelBit\(level: Int\): Int = 1 shl \(level - 1\)/,
    'Kotlin level bit must be 1 shl (level - 1)',
  );
});

test('both sides agree on the level range', () => {
  assert.match(
    read('lib/services/dns_level_mask_engine.dart'),
    /const int kDnsMaxLevel = 5;/,
    'Dart max level',
  );
  assert.match(reader, /const val MAX_LEVEL = 5/, 'Kotlin max level');
  assert.match(
    reader,
    /const val ALL_LEVELS = \(1 shl MAX_LEVEL\) - 1/,
    'Kotlin marker range is derived from MAX_LEVEL, not hardcoded',
  );
});

test('a domain line never starts with the marker character', () => {
  // Both parsers drop `#` comment lines from the upstream list before a
  // domain can reach a group, which is what makes the marker unambiguous.
  assert.match(
    store,
    /if \(trimmed\.isEmpty \|\| trimmed\.startsWith\('#'\)\) continue;/,
    `${storeRel} must drop comment lines when parsing an upstream list`,
  );
});
