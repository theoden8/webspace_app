// The runtime's variables as the model knows them are ids (CONT-012): a
// table reads SiteRuntime.vars, a RuntimeVars<SiteId>. The tables not yet
// moved read the same variables as the sites themselves, SiteRuntime's
// objectVars, which the id view is read off. This holds the files that do
// to object_view_readers.tsv, which only shrinks: a new reader fails until
// it is listed, and a listed file that no longer reads it until its row goes.
// Rung 5 until the last table moves and objectVars is deleted: a field's
// readers have no type the compiler counts.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { dartFiles, read, code } = require('./helpers/source');

const OWNER = 'lib/controllers/site_runtime.dart';
const READS = /\bobjectVars\b|RuntimeVars<WebViewModel>/;

const listed = new Map(
  read('test/js/object_view_readers.tsv')
    .split('\n')
    .filter((line) => line.trim() !== '' && !line.startsWith('#'))
    .map((line) => {
      const [file, why] = line.split('\t');
      return [file, why];
    }),
);

const readers = [...dartFiles('lib'), ...dartFiles('test')]
  .filter((f) => f !== OWNER && READS.test(code(read(f))));

test('every file that reads the runtime as sites is listed, with what reads it', () => {
  for (const f of readers) {
    assert.ok(listed.has(f), `${f} reads SiteRuntime.objectVars: move it to the id view, or list it`);
    assert.ok(listed.get(f)?.trim(), `${f} is listed without what reads it`);
  }
});

test('every listed file still reads the runtime as sites', () => {
  for (const f of listed.keys()) {
    assert.ok(readers.includes(f), `${f} no longer reads SiteRuntime.objectVars: drop its row`);
  }
});

test('the owner keeps the object view only as the source of the id view', () => {
  const owner = code(read(OWNER));
  assert.match(owner, /late final RuntimeVars<WebViewModel> objectVars = RuntimeVars\(/);
  assert.match(owner, /late final RuntimeVars<SiteId> vars = RuntimeVars\(/);
});
