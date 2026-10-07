// One verdict per request (CB attribution, BUG-004).
//
// Six hand-written copies of "does DNS or ABP block this?" once disagreed on
// order, on whether the site's toggles applied, and on which DNS level to
// ask; one asked the app-wide level, one ignored both toggles. Every Dart
// path now asks BlockDecision.decide through webview.dart's _LiveBlockLists.
// The compiler cannot stop a new path from calling a service lookup
// directly, so this gate does.

const test = require('node:test');
const assert = require('node:assert/strict');
const source = require('./helpers/source');

const read = (rel) => source.code(source.read(rel));
const LOOKUP = /\.(isBlockedAtLevel|isHostBlockedAtLevel|isBlocked|isHostBlocked)\(/g;

// The ABP probe page reads the engine's raw host verdicts as a diagnostic:
// it reports what the engine says, not what any site applies.
const DIAGNOSTIC = "handlerName: 'getAbpProbeStatus'";

test('only the BlockLists adapter asks the blockers for a verdict', () => {
  const offenders = [];
  for (const rel of source.dartFiles('lib')) {
    if (rel === 'lib/services/dns_block_service.dart'
      || rel === 'lib/services/content_blocker_service.dart') continue;
    const src = read(rel);
    const adapter = src.indexOf('final class _LiveBlockLists implements BlockLists {');
    const adapterEnd = adapter === -1 ? -1 : src.indexOf('\n}\n', adapter);
    const probe = src.indexOf(DIAGNOSTIC);
    const probeEnd = probe === -1 ? -1 : src.indexOf('addJavaScriptHandler', probe);
    for (const m of src.matchAll(LOOKUP)) {
      if (m.index > adapter && m.index < adapterEnd) continue;
      if (m.index > probe && m.index < probeEnd) continue;
      offenders.push(`${rel}:${src.slice(0, m.index).split('\n').length} ${m[1]}`);
    }
  }
  assert.deepEqual(offenders, [],
    'judge a request with BlockDecision.decide (webview.dart _verdictFor / '
    + '_judgeAndRecord), so its order and the site policy cannot drift');
});
