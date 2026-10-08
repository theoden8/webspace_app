  // For a kind that publishes a device (camera, microphone): the mode lookup
  // that never prompts, and the device the page enumerates.
  // Per spec a device label is only exposed once the page holds a capture
  // permission; flipped the first time this shim serves a stream.
  var _servedStream = false;

  // Reads the site's CURRENT mode without ever prompting. enumerateDevices
  // must not pop a permission dialog (no browser does), but it does need to
  // know whether this site is substituting the device. Cached for the
  // document: the mode only changes from per-site settings, which rebuilds
  // the webview.
  var _modePromise = null;
  function fetchMode() {
    if (_modePromise) return _modePromise;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) return Promise.resolve('block');
    _modePromise = iaw.callHandler(CONFIG.modeHandler).then(function(m) {
      return typeof m === 'string' ? m : 'block';
    }, function() {
      return 'block';
    });
    return _modePromise;
  }

  var _origGumFn = typeof patchTarget.getUserMedia === 'function'
    ? patchTarget.getUserMedia
    : (md.getUserMedia || null);
  // `this` is the live MediaDevices when called through the prototype; fall
  // back to the captured instance for a detached call.
  function callOrigGum(self, constraints) {
    if (!_origGumFn) return null;
    return _origGumFn.call(self || md, constraints);
  }

  // A page that enumerated while the synthetic device was published may hold
  // its deviceId. Once the site is on the real device, passing that id through
  // would make the platform reject the request as overconstrained, so drop
  // just that constraint from the [key] half and let the OS pick.
  function withoutSyntheticDeviceId(constraints, key) {
    var c = constraints && constraints[key];
    if (!c || c === true || !c.deviceId) return constraints;
    var d = c.deviceId;
    var wanted = typeof d === 'string' ? d : (d.exact || d.ideal);
    if (wanted !== DEVICE_ID) return constraints;
    var half = {};
    for (var k in c) {
      if (k !== 'deviceId' && Object.prototype.hasOwnProperty.call(c, k)) half[k] = c[k];
    }
    var out = {};
    for (var o in constraints) {
      if (Object.prototype.hasOwnProperty.call(constraints, o)) out[o] = constraints[o];
    }
    out[key] = half;
    return out;
  }

