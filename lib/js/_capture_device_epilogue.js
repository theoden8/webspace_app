  // For a kind that publishes a device: the `enumerateDevices` and
  // legacy-callback patches, closing the shim.
  // Legacy callback API. Some older bundles still feature-detect it, and
  // leaving it unpatched would route them past every shim. Routed through the
  // live public entry point so it stays correct whichever capture shim
  // installed last.
  var nav = globalThis.navigator;
  if (nav && (nav.getUserMedia || nav.webkitGetUserMedia || nav.mozGetUserMedia)) {
    var legacy = function getUserMedia(constraints, success, failure) {
      Promise.resolve().then(function() {
        return md.getUserMedia(constraints);
      }).then(
        function(s) { if (success) success(s); },
        function(e) { if (failure) failure(e); });
    };
    ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia'].forEach(function(name) {
      if (!nav[name]) return;
      try { nav[name] = asNative(legacy, name); } catch (e) {}
    });
  }

  // In VIRTUAL mode: hide the real devices of this kind (getUserMedia will not
  // open them, so listing them is a lie the page could catch by selecting one
  // by deviceId) and publish exactly one synthetic device.
  //
  // In ASK mode on a device with NONE of this kind, publish the synthetic one
  // too: otherwise a page that enumerates first concludes there is no device
  // and never calls getUserMedia, so the user is never offered the "use a
  // file" popup at all.
  //
  // In REAL and BLOCK mode (and ASK where a real device exists): pass the
  // platform list through untouched. Masking there would break the common
  // "pick a device" UI, and in REAL mode would misreport the hardware the
  // user chose to expose (MIC-009).
  //
  // Per spec, labels are only exposed once the page holds a capture
  // permission, so the label is blank until this shim has served a stream.
  var _origEnumerateFn = typeof patchTarget.enumerateDevices === 'function'
    ? patchTarget.enumerateDevices
    : (md.enumerateDevices || null);
  var enumerateDevices = function enumerateDevices() {
    var self = this && this.enumerateDevices ? this : md;
    var base = _origEnumerateFn
      ? _origEnumerateFn.call(self)
      : Promise.resolve([]);
    return Promise.all([Promise.resolve(base), fetchMode()]).then(function(r) {
      var list = r[0] || [];
      var mode = r[1];
      var hasReal = false;
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].kind === CONFIG.deviceKind) hasReal = true;
      }
      var publishSynthetic = mode === 'virtual' || (mode === 'ask' && !hasReal);
      if (!publishSynthetic) return list;

      var out = [];
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].kind !== CONFIG.deviceKind) out.push(list[j]);
      }
      var info = {
        deviceId: DEVICE_ID,
        kind: CONFIG.deviceKind,
        label: _servedStream ? DEVICE_LABEL : '',
        groupId: GROUP_ID,
      };
      info.toJSON = function toJSON() {
        return {
          deviceId: info.deviceId,
          kind: info.kind,
          label: info.label,
          groupId: info.groupId,
        };
      };
      out.push(info);
      return out;
    });
  };
  defineOnProto('enumerateDevices', asNative(enumerateDevices, 'enumerateDevices'));
