// What `webspace_lints` lets through by hand: every `// ignore:` of one of
// its rules, listed here with what would lift it. An ignore is how a rule's
// debt is written at the site, and this list is where it only shrinks: a new
// ignore fails until it is listed, and a fixed one until its entry goes.
// `ignore_for_file` would let new code in unseen, so it is refused outright.
// Rung 5: the analyzer honours an ignore comment wherever it is written.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { dartFiles, read, code, lineAt } = require('./helpers/source');

const DIRS = ['lib', 'integration_test', 'test_driver', 'test', 'tool'];

// By rule, the files that ignore it, each with how many sites and why.
const LEFT = {
  catch_all: {
    'test/helpers/walk/walk_runner.dart': {
      sites: 3,
      why: 'a walk reports every failure of the run it drives, the Error a bug '
        + 'raises most of all: shrinking a failing run to its shortest trace '
        + "needs each run's failure in hand.",
    },
    'test/helpers/walk/schedules.dart': {
      sites: 2,
      why: 'a schedule enumeration reports every failure of the schedule it '
        + 'runs, for the same reason as the walk runner.',
    },
    'lib/services/socks_connect.dart':
      'socks5_proxy 2.1.1 throws plain Exception(...) from its handshake '
      + '(socks_client.dart:139-208), so no narrower type exists; the adapter '
      + 'turns it into SocksHandshakeFailure. Lifted by a typed failure upstream '
      + 'or an in-repo SOCKS client.',
    'lib/services/engine_image.dart':
      'the Flutter engine reports undecodable bytes and a failed raster as a '
      + 'plain Exception (sky_engine painting.dart: getNextFrame, Picture.toImage, '
      + '_futurize), so no narrower type exists; the owner turns it into '
      + 'EngineImageFailure. Lifted by a typed failure in dart:ui.',
    'lib/controllers/link_controller.dart':
      'the inbound dispatch runs whatever a link asks (a nested open, a new '
      + 'site, a bind, an activation), whose failures are open across those '
      + 'flows, and nothing else logs what escapes a stream listener here. '
      + 'Lifted when each dispatch action owns its failures.',
    'lib/services/background_task_service.dart':
      'the background refresh runs the whole wake, whose failures are open '
      + 'across its engines, and Android invokes it with no result callback, so '
      + 'this line is the only record a refresh failed. Lifted when each wake '
      + 'step owns its failures.',
  },
  layer_import: {
    'lib/services/cookie_isolation.dart':
      'the jar engine works over the WebViewModels it is handed: their ids, '
      + 'URLs, incognito and cookie blocks, and the webview a clear disposes. '
      + 'Lifted by a narrow site type the model implements, declared in '
      + 'services.',
    'lib/services/site_unload_engine.dart':
      'the unload engine plans and runs over the WebViewModels the page holds: '
      + 'their proxy, their tabs\' hosts and binding, and the webview cache an '
      + 'unload clears. Lifted by a narrow site type, as for the jar.',
  },
  raw_http_client: {
    'lib/design_gallery/roboto.dart':
      'the design builds fetch their own bundled Roboto by a URL relative to '
      + 'the page, which names no third party, and a web build has no proxy '
      + 'to apply. Lifted when the faces load from the asset bundle.',
    'lib/services/tor_moat_client.dart':
      'moat asks for bridges because Tor is unreachable, so no circuit can '
      + 'carry it; the file header says why it goes direct and what the UI '
      + 'tells the user (TOR-016). Lifted by a domain-fronted transport.',
  },
};

const IGNORE = /\/\/\s*(ignore|ignore_for_file):([^\n]*)/g;

/** Each ignore of a webspace_lints rule in the comments of `src`. */
function ignores(src, rel) {
  const comments = code(src);
  const out = [];
  for (const m of src.matchAll(IGNORE)) {
    if (comments[m.index] === src[m.index]) continue;
    for (const name of m[2].split(',').map((s) => s.trim())) {
      const rule = /^webspace_lints\/(\w+)/.exec(name)?.[1];
      if (rule) {
        out.push({ rule, file: rel, line: lineAt(src, m.index), forFile: m[1] === 'ignore_for_file' });
      }
    }
  }
  return out;
}

test('every ignore of a webspace_lints rule is listed with what would lift it', () => {
  const found = DIRS.flatMap((dir) => dartFiles(dir).flatMap((f) => ignores(read(f), f)));
  assert.deepEqual(found.filter((i) => i.forFile).map((i) => `${i.file}:${i.line}`), [],
    'ignore_for_file would let new code in unseen; ignore the line, and list it here');
  const counted = {};
  for (const { rule, file } of found) {
    counted[rule] ??= {};
    counted[rule][file] = (counted[rule][file] ?? 0) + 1;
  }
  const listed = {};
  for (const [rule, byFile] of Object.entries(LEFT)) {
    listed[rule] = {};
    for (const [file, entry] of Object.entries(byFile)) {
      listed[rule][file] = typeof entry === 'string' ? 1 : entry.sites;
    }
  }
  assert.deepEqual(counted, listed,
    'a new ignore is listed here with what would lift it; a fixed one leaves the list');
});

test('the gate reads ignores from comments only', () => {
  const src = [
    '// ignore: webspace_lints/catch_all',
    "final s = '// ignore: webspace_lints/catch_all';",
    '  } on Exception { // ignore: unused_local_variable, webspace_lints/positional_parameters',
    '// ignore_for_file: webspace_lints/catch_all',
    '// ignore: avoid_print',
  ].join('\n');
  assert.deepEqual(ignores(src, 'x.dart'), [
    { rule: 'catch_all', file: 'x.dart', line: 1, forFile: false },
    { rule: 'positional_parameters', file: 'x.dart', line: 3, forFile: false },
    { rule: 'catch_all', file: 'x.dart', line: 4, forFile: true },
  ]);
});
