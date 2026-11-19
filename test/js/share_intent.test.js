// Android share intent gate (LIR-005).
//
// Two halves of the requirement live where no type reaches them: the
// manifest's intent filter, which the OS reads, and the flags the share
// path leaves off, which only the activity's code shows. The URL a share's
// text carries is ShareText.urlIn, tested on the JVM (ShareTextTest.kt).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const manifest = read('android/app/src/main/AndroidManifest.xml');
const activityRel =
  'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MainActivity.kt';
const activity = read(activityRel);

function mainActivity() {
  const m = manifest.match(
    /<activity\b[^>]*android:name="\.MainActivity"[\s\S]*?<\/activity>/);
  assert.ok(m, 'the manifest declares MainActivity');
  return m[0];
}

function body(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `${signature} is in ${activityRel}`);
  let depth = 0;
  for (let i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`${signature} never closes`);
}

test('LIR-005: MainActivity takes a shared text/plain', () => {
  const filters = mainActivity().match(/<intent-filter>[\s\S]*?<\/intent-filter>/g) ?? [];
  const send = filters.find((f) => f.includes('android.intent.action.SEND"'));
  assert.ok(send, 'MainActivity has an ACTION_SEND intent filter');
  assert.match(send, /android\.intent\.category\.DEFAULT/);
  assert.match(send, /android:mimeType="text\/plain"/);
});

test('LIR-005: the share path asks for no new task, so Back returns to the sharer', () => {
  for (const fn of ['private fun captureSharePayload(', 'private fun extractShareUrl(']) {
    assert.doesNotMatch(body(activity, fn), /FLAG_ACTIVITY_NEW_TASK/, fn);
  }
  assert.match(body(activity, 'private fun extractShareUrl('), /ShareText\.urlIn\(/,
    'the URL comes from ShareText.urlIn, which ShareTextTest.kt holds');
});
