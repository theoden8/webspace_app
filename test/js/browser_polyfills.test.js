// The stand-ins makeDom (helpers/load_shim.js) gives jsdom for the browser
// APIs it lacks are inert (SHIM-TEST-002): a shim's `if (origFn)` guard sees
// a function to wrap, and a test of the shim asserts the shape of its
// override, never behaviour a stub made up.
//
// Planted mistake: the matchMedia stub answering `matches: true` failed the
// first test.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom } = require('./helpers/load_shim');

test('SHIM-TEST-002: matchMedia matches nothing and echoes its query', () => {
  const { window } = makeDom();
  const list = window.matchMedia('(prefers-color-scheme: dark)');
  assert.equal(list.matches, false);
  assert.equal(list.media, '(prefers-color-scheme: dark)');
  assert.equal(list.dispatchEvent(), false);
});

test('SHIM-TEST-002: Geolocation answers no position', async () => {
  const { window } = makeDom();
  const calls = [];
  const geo = window.navigator.geolocation;
  assert.ok(geo instanceof window.Geolocation);
  assert.equal(geo.getCurrentPosition(() => calls.push('success'), () => calls.push('error')), undefined);
  assert.equal(geo.watchPosition(() => calls.push('watch')), 0);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(calls, []);
});

test('SHIM-TEST-002: Permissions reports prompt for whatever it is asked', async () => {
  const { window } = makeDom();
  const status = await window.navigator.permissions.query({ name: 'geolocation' });
  assert.equal(status.state, 'prompt');
  assert.equal(status.name, 'geolocation');
});

test('SHIM-TEST-002: RTCPeerConnection records the configuration it is given and opens nothing', async () => {
  const { window } = makeDom();
  const config = { iceServers: [{ urls: 'stun:stun.example' }], iceTransportPolicy: 'relay' };
  const pc = new window.RTCPeerConnection(config);
  assert.deepEqual(pc.getConfiguration(), config);
  assert.equal(await pc.setLocalDescription({ type: 'offer', sdp: 'v=0' }), undefined);
  assert.deepEqual(Object.keys(pc).sort(), ['__config', '__lastSdp']);
});
