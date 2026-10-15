// Every handler names what it handles (Style: no catch-alls).
// Rung 5: `avoid_catches_without_on_clauses` sees a bare `catch` and nothing
// else. No lint reads which type an `on` clause or a `test:` names, so
// `on Exception` passes the analyzer while catching everything nobody
// expected; a `catchError` takes any function, so one with no `test:`
// swallows an Error, a bug; and a stream's `onError` that drops its argument
// hides the failure where nothing sees it. Code of ours throws a named type,
// never a plain `Exception(...)`, which only `on Exception` could catch, and
// a test's fake throws what the interface it models throws.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { dartFiles, read, code, lineAt, enclosed } = require('./helpers/source');

const DIRS = ['lib', 'integration_test', 'test_driver', 'test', 'tool'];

const GENERIC = 'Exception|Object|dynamic|Error';
const RULES = [
  {
    // After the try's `}` (or the previous clause's), so `extension X on Object {` is not one.
    re: new RegExp(`\\}\\s*on\\s+(?:${GENERIC})\\b\\s*(?:catch\\b|\\{)`, 'g'),
    why: 'an on clause names the types its call throws, never Exception, Object, dynamic or Error',
  },
  {
    re: new RegExp(`\\btest:\\s*\\(\\s*(?:\\w+\\s+)?\\w+\\s*\\)\\s*=>\\s*\\w+\\s+is\\s+(?:${GENERIC})\\b`, 'g'),
    why: 'a test: predicate names the types it handles',
  },
  {
    re: new RegExp(`\\.onError<\\s*(?:${GENERIC})\\s*>`, 'g'),
    why: "a future's onError names the types it handles",
  },
  {
    re: /(?:\bonError:\s*|\.onError\(\s*)\(\s*(?:Object\s+|dynamic\s+)?_+\s*(?:,\s*(?:StackTrace\s+)?_+\s*)?\)/g,
    why: 'an onError that drops its error swallows every failure; handleError(..., test:) names the ones it expects',
  },
  {
    re: /(?<![\w.$])Exception\s*\(/g,
    why: 'a plain Exception can only be caught as Exception; make a type that says what failed',
  },
];

// The generic catches left, each with what would lift it, and how many sites
// it covers. The list only shrinks.
const LEFT = {
  'test/helpers/walk/walk_runner.dart': {
    sites: 3,
    why: 'a walk reports every failure of the run it drives, the Error a bug '
      + 'raises most of all: shrinking a failing run to its shortest trace '
      + 'needs each run\'s failure in hand.',
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
    "the Flutter engine reports undecodable bytes and a failed raster as a "
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
};

/** `path:line  why` for each handler in `src` that names no type. */
function untyped(src, rel) {
  const text = code(src, { strings: true });
  const out = [];
  for (const { re, why } of RULES) {
    for (const m of text.matchAll(re)) out.push(`${rel}:${lineAt(src, m.index)}  ${why}`);
  }
  for (const m of text.matchAll(/\.(catchError|handleError)\(/g)) {
    const { body } = enclosed(text, m.index + m[0].length - 1, '(');
    if (!/\btest:/.test(body)) {
      out.push(`${rel}:${lineAt(src, m.index)}  a ${m[1]} without test: also swallows Errors`);
    }
  }
  return out;
}

test('a handler names what it handles', () => {
  const found = DIRS.flatMap((dir) => dartFiles(dir).flatMap((f) => untyped(read(f), f)));
  const left = [];
  for (const [file, entry] of Object.entries(LEFT)) {
    const { sites, why } = typeof entry === 'string' ? { sites: 1, why: entry } : entry;
    const hits = found.filter((f) => f.startsWith(`${file}:`));
    assert.equal(hits.length, sites,
      `${file} is listed with ${sites} generic catch(es) left (${why}) but has ${hits.length}`);
    left.push(...hits);
  }
  assert.deepEqual(found.filter((f) => !left.includes(f)), [],
    'name the exceptions the call throws, read from its source; drop the handler when the failure already has an owner');
});

test('the gate catches each generic form and passes the typed ones', () => {
  const planted = [
    'try { f(); } on Exception { }',
    'try { f(); } on Exception catch (e) { log(e); }',
    'try { f(); } on FormatException { } on Object catch (e) { }',
    'try { f(); } on dynamic { }',
    'try { f(); } on Error catch (e) { }',
    "f().catchError((Object _) => null, test: (e) => e is Exception);",
    'f().catchError((Object e) => null);',
    's.listen(add, onError: (Object _) {});',
    's.listen(add, onError: (_) => close());',
    'f().then(g, onError: (Object _, StackTrace _) => null);',
    "throw Exception('List not found');",
    'socket.listen(add)..onError((Object _) {});',
    'f().onError<Exception>((e, st) => null);',
    's.handleError((Object _) {});',
    "f().catchError((Object _) => null, test: (Object e) => e is Exception);",
    "Error.throwWithStackTrace(Exception('x'), st);",
  ];
  for (const src of planted) {
    assert.equal(untyped(src, 'x.dart').length, 1, `not caught: ${src}`);
  }
  const typed = [
    'try { f(); } on SocketException catch (e) { } on PlatformException { }',
    'try { f(); } on IOException { }',
    'extension X on Object { }',
    'mixin M on Object { }',
    "f().catchError((Object _) => null, test: (e) => e is TimeoutException);",
    's.handleError((Object _) {}, test: (e) => e is SocketException);',
    's.listen(add, onError: (Object e, StackTrace st) => done.completeError(e, st));',
    "final s = 'try { } on Exception { }';",
    '// } on Exception {',
    "throw const FormatException('bad');",
    'throw ProxyRefused(message);',
    'f().onError<SocketException>((e, st) => null);',
    'sub.onError((Object e, StackTrace st) => done.completeError(e, st));',
    "f().catchError((Object _) => null, test: (Object e) => e is SocketException);",
    "throw const FormatException('x');",
    'final class Refused implements Exception {}',
  ];
  for (const src of typed) {
    assert.deepEqual(untyped(src, 'x.dart'), [], `flagged a typed handler: ${src}`);
  }
});
