// The desktop entry and the metainfo carry the application id, which CMake
// writes into them from APPLICATION_ID in linux/CMakeLists.txt. A template that
// names an id by hand would ship files pointing at another app, and
// configure_file cannot reject that, so this gate holds each id field to its
// placeholder.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

test('the desktop entry takes its icon name from the application id (PLATFORM-008)', () => {
  assert.match(read('linux/webspace.desktop.in'), /^Icon=@APPLICATION_ID@$/m);
});

test('the metainfo takes its ids from the application id (PLATFORM-008)', () => {
  const metainfo = read('linux/webspace.metainfo.xml.in');
  assert.match(metainfo, /<id>@APPLICATION_ID@<\/id>/);
  assert.match(metainfo, /<developer id="@DEVELOPER_ID@">/);
  assert.match(metainfo, /<launchable type="desktop-id">@APPLICATION_ID@\.desktop<\/launchable>/);
});
