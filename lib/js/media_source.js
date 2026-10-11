// MediaSource for a page told it is on a desktop.
//
// iOS WebKit exposes `MediaSource` only for desktop-class browsing, which an
// app running as an iPhone app (on a phone, or as the iOS build on a Mac) never
// gets, whatever its content mode. It always exposes `ManagedMediaSource`, the
// same API with eviction hints. A desktop page tests `window.MediaSource` and
// has no other way to play an adaptive stream, so this hands it the managed
// one.
//
// WebKit keeps a managed source closed (`sourceopen` never fires) until its
// element can no longer be handed to AirPlay or offers an AirPlay
// alternative (HTMLMediaElement::deferredMediaSourceOpenCanProgress). A page
// written for MediaSource does neither, so remote playback is disabled on the
// element before a managed source is attached to it.
(function () {
  'use strict';
  // @include _native_fn.js
  if (typeof window.MediaSource === 'function') return;
  var Managed = window.ManagedMediaSource;
  if (typeof Managed !== 'function') return;

  var managedUrls = new Set();
  var createObjectURL = URL.createObjectURL;
  var revokeObjectURL = URL.revokeObjectURL;
  URL.createObjectURL = asNative(function createObjectURL_(obj) {
    var url = createObjectURL.apply(this, arguments);
    if (obj instanceof Managed) managedUrls.add(String(url));
    return url;
  }, 'createObjectURL');
  URL.revokeObjectURL = asNative(function revokeObjectURL_(url) {
    managedUrls.delete(String(url));
    return revokeObjectURL.apply(this, arguments);
  }, 'revokeObjectURL');

  var proto = HTMLMediaElement.prototype;
  function guardSetter(name, isManaged) {
    var desc = Object.getOwnPropertyDescriptor(proto, name);
    if (!desc || !desc.set) return;
    Object.defineProperty(proto, name, {
      configurable: true,
      enumerable: desc.enumerable,
      get: desc.get,
      set: asNative(function (value) {
        if (isManaged(value)) this.disableRemotePlayback = true;
        desc.set.call(this, value);
      }, 'set ' + name),
    });
  }
  guardSetter('src', function (value) { return managedUrls.has(String(value)); });
  guardSetter('srcObject', function (value) { return value instanceof Managed; });

  var setAttribute = Element.prototype.setAttribute;
  proto.setAttribute = asNative(function setAttribute_(name, value) {
    if (String(name).toLowerCase() === 'src' && managedUrls.has(String(value))) {
      this.disableRemotePlayback = true;
    }
    return setAttribute.apply(this, arguments);
  }, 'setAttribute');

  window.MediaSource = Managed;
  if (typeof window.SourceBuffer !== 'function' &&
      typeof window.ManagedSourceBuffer === 'function') {
    window.SourceBuffer = window.ManagedSourceBuffer;
  }
})();
