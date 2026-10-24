// APPLICATION_ID in linux/CMakeLists.txt names the GTK application, the
// window's Wayland app ID and the desktop files. A package passes its own as
// WEBSPACE_APPLICATION_ID (the flatpak's manifest, in the separate packaging
// repo, does); every other build keeps the ID earlier releases ran under,
// which path_provider's data directory and the keyring entry are named after.
// No test here runs CMake, so this gate holds the rule's text.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const CMAKE = 'linux/CMakeLists.txt';

test('CMake takes the application id from WEBSPACE_APPLICATION_ID, else the released one (PLATFORM-009)', () => {
  const cmake = read(CMAKE);
  assert.match(cmake, new RegExp([
    '^if\\(NOT "\\$ENV\\{WEBSPACE_APPLICATION_ID\\}" STREQUAL ""\\)',
    '  set\\(APPLICATION_ID "\\$ENV\\{WEBSPACE_APPLICATION_ID\\}"\\)',
    'else\\(\\)',
    '  set\\(APPLICATION_ID "org\\.codeberg\\.theoden8\\.webspace"\\)',
    'endif\\(\\)$',
  ].join('\n'), 'm'), `${CMAKE} does not take APPLICATION_ID from a non-empty WEBSPACE_APPLICATION_ID, falling back to org.codeberg.theoden8.webspace`);
  assert.equal(cmake.match(/^\s*set\(APPLICATION_ID\b/gm).length, 2,
    `${CMAKE} sets APPLICATION_ID outside the WEBSPACE_APPLICATION_ID rule`);
});
