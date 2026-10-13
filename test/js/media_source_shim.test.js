// Tier 1: jsdom assertions for lib/js/media_source.js (DM-007). jsdom has
// neither MediaSource nor ManagedMediaSource, so each test installs the half
// of WebKit's surface it models: an iPhone-class WebKit exposes only the
// managed source, a desktop one exposes both.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');
const { scriptOf } = require('./helpers/script_of');

function iPhoneClassWebKit({ withMediaSource }) {
  class MediaSourceBase {}
  class ManagedMediaSource extends MediaSourceBase {}
  class ManagedSourceBuffer {}
  window.ManagedMediaSource = ManagedMediaSource;
  window.ManagedSourceBuffer = ManagedSourceBuffer;
  if (withMediaSource) window.MediaSource = MediaSourceBase;
  let next = 0;
  URL.createObjectURL = function createObjectURL() { next += 1; return 'blob:https://example.com/' + next; };
  URL.revokeObjectURL = function revokeObjectURL() {};
  const objects = new WeakMap();
  Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
    configurable: true,
    enumerable: true,
    get() { return objects.get(this) ?? null; },
    set(value) { objects.set(this, value); },
  });
}

function domWith({ withMediaSource }) {
  const dom = makeDom();
  runInDom(dom, scriptOf(iPhoneClassWebKit, { withMediaSource }));
  runInDom(dom, pageJs('media_source'));
  return dom;
}

test('a page without MediaSource gets the managed one', () => {
  const { window } = domWith({ withMediaSource: false });
  assert.equal(window.MediaSource, window.ManagedMediaSource);
  assert.equal(window.SourceBuffer, window.ManagedSourceBuffer);
});

test('a page that has MediaSource keeps it untouched', () => {
  const { window } = domWith({ withMediaSource: true });
  assert.notEqual(window.MediaSource, window.ManagedMediaSource);
  assert.equal(window.SourceBuffer, undefined);
  assert.equal(window.URL.createObjectURL.name, 'createObjectURL');
});

test('without ManagedMediaSource nothing is installed', () => {
  const dom = makeDom();
  runInDom(dom, pageJs('media_source'));
  assert.equal(dom.window.MediaSource, undefined);
});

test('attaching a managed source by src disables remote playback first', () => {
  const { window } = domWith({ withMediaSource: false });
  const video = window.document.createElement('video');
  const url = window.URL.createObjectURL(new window.MediaSource());
  video.src = url;
  assert.equal(video.disableRemotePlayback, true);
  assert.equal(video.getAttribute('src'), url);
});

test('attaching a managed source by setAttribute disables remote playback', () => {
  const { window } = domWith({ withMediaSource: false });
  const video = window.document.createElement('video');
  video.setAttribute('src', window.URL.createObjectURL(new window.MediaSource()));
  assert.equal(video.disableRemotePlayback, true);
});

test('attaching a managed source by srcObject disables remote playback', () => {
  const { window } = domWith({ withMediaSource: false });
  const video = window.document.createElement('video');
  const source = new window.MediaSource();
  video.srcObject = source;
  assert.equal(video.disableRemotePlayback, true);
  assert.equal(video.srcObject, source);
});

test('an ordinary or revoked URL leaves remote playback alone', () => {
  const { window } = domWith({ withMediaSource: false });
  const plain = window.document.createElement('video');
  plain.src = 'https://example.com/clip.mp4';
  assert.notEqual(plain.disableRemotePlayback, true);

  const revoked = window.document.createElement('video');
  const url = window.URL.createObjectURL(new window.MediaSource());
  window.URL.revokeObjectURL(url);
  revoked.src = url;
  assert.notEqual(revoked.disableRemotePlayback, true);
});

test('the patched functions read as native', () => {
  const { window } = domWith({ withMediaSource: false });
  assert.match(String(window.URL.createObjectURL), /\[native code\]/);
  assert.match(String(window.HTMLMediaElement.prototype.setAttribute), /\[native code\]/);
});
