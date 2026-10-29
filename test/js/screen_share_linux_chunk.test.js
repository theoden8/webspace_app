// SHARE-018 on Linux: a frame's chunk is read once.
//
// The PipeWire producer shares the chunk's memory with the runner and may
// rewrite it while the runner reads it, so an offset checked against the
// buffer and read again to address it can address anything. Every read of a
// chunk field is one atomic load into a local, which is what is checked and
// used. Not a type and not a run: the double read is a race no
// deterministic test reproduces, so this reads the source.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const source = read('linux/screen_share.cc');

test('every chunk field is read through one atomic load', () => {
  const reads = source.match(/chunk->\w+/g) ?? [];
  assert.ok(reads.length > 0, 'the chunk is no longer read here');
  const loaded = source.match(/__atomic_load_n\(&data\.chunk->\w+, __ATOMIC_RELAXED\)/g) ?? [];
  assert.equal(reads.length, loaded.length,
    'a chunk field read outside its single load can change between the check and the use');
  assert.equal(new Set(loaded).size, loaded.length, 'and each field is loaded once');
});
