(function() {
  if (window.__wsLocShimInstalled) return;
  window.__wsLocShimInstalled = true;

  var STATIC_LOC = false;
  var LIVE_LOC = false;
  var LAT = 0.0;
  var LNG = 0.0;
  var ACC = 50.0;
  var TZ = null;
  var WRTC = "relay";

  // --- Function.prototype.toString hardening ---
  // Keyed by WeakMap so overridden functions stringify as native. Patched
  // exactly once — subsequent reloads via evaluateJavascript are no-ops.
  var _origFnToString = Function.prototype.toString;
  var _stubs = window.__wsFnStubs || new WeakMap();
  window.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    _stubs.set(fn, 'function ' + name + '() { [native code] }');
    return fn;
  }
  if (!window.__wsFnToStringPatched) {
    window.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    _stubs.set(patched, 'function toString() { [native code] }');
    try {
      Function.prototype.toString = patched;
    } catch (e) {}
  }

  // --- Geolocation: spoof (static) or live (real device GPS via Dart) ---
  if ((STATIC_LOC || LIVE_LOC) && navigator.geolocation) {
    var _coordsProto = (typeof GeolocationCoordinates !== 'undefined')
      ? GeolocationCoordinates.prototype : Object.prototype;
    var _posProto = (typeof GeolocationPosition !== 'undefined')
      ? GeolocationPosition.prototype : Object.prototype;

    function makeCoordsFrom(lat, lng, acc) {
      // Sub-meter jitter so watchPosition doesn't return identical frames
      // when the device is stationary (also masks discretized GPS rounding).
      var jLat = (Math.random() - 0.5) * 0.00002;
      var jLng = (Math.random() - 0.5) * 0.00002;
      var c = Object.create(_coordsProto);
      Object.defineProperties(c, {
        latitude: { value: lat + jLat, enumerable: true },
        longitude: { value: lng + jLng, enumerable: true },
        accuracy: { value: acc > 0 ? acc : 50, enumerable: true },
        altitude: { value: null, enumerable: true },
        altitudeAccuracy: { value: null, enumerable: true },
        heading: { value: null, enumerable: true },
        speed: { value: null, enumerable: true },
      });
      return c;
    }
    function makePositionFrom(lat, lng, acc) {
      var p = Object.create(_posProto);
      Object.defineProperties(p, {
        coords: { value: makeCoordsFrom(lat, lng, acc), enumerable: true },
        timestamp: { value: Date.now(), enumerable: true },
      });
      return p;
    }
    function makePositionStatic() {
      return makePositionFrom(LAT, LNG, ACC);
    }

    // Map a Dart status payload to a GeolocationPositionError code:
    //   1 = PERMISSION_DENIED, 2 = POSITION_UNAVAILABLE, 3 = TIMEOUT.
    function geolocationErrorFor(payload) {
      var code = 2;
      if (payload && payload.status === 'permission_denied') code = 1;
      else if (payload && payload.status === 'permission_denied_forever') code = 1;
      else if (payload && payload.status === 'timeout') code = 3;
      return {
        code: code,
        message: (payload && payload.message) || 'unknown',
        PERMISSION_DENIED: 1,
        POSITION_UNAVAILABLE: 2,
        TIMEOUT: 3,
      };
    }

    // Single source of truth for fetching a fresh real fix in live mode.
    // Returns a Promise that resolves with either {ok, lat, lng, acc} or
    // {error, payload}. The handler is registered Dart-side only when the
    // mode is `live`; if it's missing here we still defensively fail
    // closed so a legacy/no-handler page doesn't hang forever.
    function getLiveFix() {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        return window.flutter_inappwebview.callHandler('getRealLocation').then(function(res) {
          if (res && res.status === 'ok') {
            return { ok: true, lat: res.latitude, lng: res.longitude, acc: res.accuracy };
          }
          return { ok: false, payload: res };
        }, function() {
          return { ok: false, payload: { status: 'error', message: 'handler_failed' } };
        });
      }
      return Promise.resolve({ ok: false, payload: { status: 'error', message: 'no_handler' } });
    }

    var _latency = 150 + Math.random() * 250;
    var _getCurrent = function getCurrentPosition(success, error, options) {
      if (LIVE_LOC) {
        getLiveFix().then(function(r) {
          if (r.ok) {
            if (success) { try { success(makePositionFrom(r.lat, r.lng, r.acc)); } catch (e) {} }
          } else if (error) {
            try { error(geolocationErrorFor(r.payload)); } catch (e) {}
          }
        });
      } else {
        setTimeout(function() {
          if (success) { try { success(makePositionStatic()); } catch (e) {} }
        }, _latency);
      }
    };
    asNative(_getCurrent, 'getCurrentPosition');

    var _watchId = 0;
    var _watchTimers = {};
    var _watch = function watchPosition(success, error, options) {
      var id = ++_watchId;
      if (LIVE_LOC) {
        var tick = function() {
          getLiveFix().then(function(r) {
            if (r.ok) {
              if (success) { try { success(makePositionFrom(r.lat, r.lng, r.acc)); } catch (e) {} }
            } else if (error) {
              try { error(geolocationErrorFor(r.payload)); } catch (e) {}
            }
          });
        };
        // Fire once immediately, then poll. 5s is the same cadence used by
        // most real GPS receivers under battery-conservative settings; the
        // page can call clearWatch to stop. We don't expose this period to
        // pages — `options.maximumAge` etc. are intentionally ignored.
        setTimeout(tick, _latency);
        _watchTimers[id] = setInterval(tick, 5000);
      } else {
        setTimeout(function() {
          if (success) { try { success(makePositionStatic()); } catch (e) {} }
        }, _latency);
        _watchTimers[id] = setInterval(function() {
          if (success) { try { success(makePositionStatic()); } catch (e) {} }
        }, 1000);
      }
      return id;
    };
    asNative(_watch, 'watchPosition');

    var _clear = function clearWatch(id) {
      var t = _watchTimers[id];
      if (t) { clearInterval(t); delete _watchTimers[id]; }
    };
    asNative(_clear, 'clearWatch');

    // Override on the prototype so `Geolocation.prototype.getCurrentPosition`
    // is the patched version — sites cannot capture the unpatched reference.
    if (typeof Geolocation !== 'undefined') {
      try {
        Object.defineProperty(Geolocation.prototype, 'getCurrentPosition',
          { value: _getCurrent, configurable: true, writable: true });
        Object.defineProperty(Geolocation.prototype, 'watchPosition',
          { value: _watch, configurable: true, writable: true });
        Object.defineProperty(Geolocation.prototype, 'clearWatch',
          { value: _clear, configurable: true, writable: true });
      } catch (e) {}
    }

    // Permissions API: geolocation should report 'granted' since
    // getCurrentPosition resolves without prompting.
    if (navigator.permissions && navigator.permissions.query) {
      var _origQuery = navigator.permissions.query.bind(navigator.permissions);
      var _query = function query(p) {
        if (p && p.name === 'geolocation') {
          var status = {};
          Object.defineProperties(status, {
            state: { value: 'granted', enumerable: true },
            status: { value: 'granted', enumerable: true },
            onchange: { value: null, writable: true, enumerable: true },
          });
          status.addEventListener = function() {};
          status.removeEventListener = function() {};
          status.dispatchEvent = function() { return true; };
          return Promise.resolve(status);
        }
        return _origQuery(p);
      };
      asNative(_query, 'query');
      try { navigator.permissions.query = _query; } catch (e) {}
    }
  }

  // --- Timezone spoofing ---
  if (TZ) {
    var _nativeDTF = Intl.DateTimeFormat;

    // Compute the target zone's UTC offset (minutes, sign flipped to match
    // Date.prototype.getTimezoneOffset: positive when local is behind UTC)
    // at the given Date instant. Respects DST by going through Intl.
    function targetOffsetMinutes(date) {
      var t = date.getTime();
      if (isNaN(t)) return NaN;
      try {
        var parts = {};
        new _nativeDTF('en-US', {
          timeZone: TZ,
          hourCycle: 'h23',
          year: 'numeric', month: '2-digit', day: '2-digit',
          hour: '2-digit', minute: '2-digit', second: '2-digit',
        }).formatToParts(date).forEach(function(p) { parts[p.type] = p.value; });
        var asUtc = Date.UTC(
          +parts.year, +parts.month - 1, +parts.day,
          +parts.hour, +parts.minute, +parts.second);
        return -Math.round((asUtc - t) / 60000);
      } catch (e) {
        return date.getTimezoneOffset();
      }
    }

    var _origGetTZO = Date.prototype.getTimezoneOffset;
    var _getTZO = function getTimezoneOffset() {
      return targetOffsetMinutes(this);
    };
    asNative(_getTZO, 'getTimezoneOffset');
    try { Date.prototype.getTimezoneOffset = _getTZO; } catch (e) {}

    // Date.prototype.toString: real-browser format is
    //   "Tue Apr 21 2026 10:30:00 GMT+0900 (Japan Standard Time)"
    // We rebuild it with the spoofed zone. Sites that regex the tz
    // abbreviation or offset will see the spoofed values.
    function pad2(n) { n = String(n); return n.length < 2 ? '0' + n : n; }
    var _toString = function toString() {
      var t = this.getTime();
      if (isNaN(t)) return 'Invalid Date';
      var parts = {};
      try {
        new _nativeDTF('en-US', {
          timeZone: TZ, hourCycle: 'h23',
          weekday: 'short', month: 'short', day: '2-digit', year: 'numeric',
          hour: '2-digit', minute: '2-digit', second: '2-digit',
          timeZoneName: 'long',
        }).formatToParts(this).forEach(function(p) { parts[p.type] = p.value; });
      } catch (e) {
        try { return Date.prototype.toISOString.call(this); } catch (_) { return ''; }
      }
      var off = targetOffsetMinutes(this);
      var sign = off <= 0 ? '+' : '-';
      var abs = Math.abs(off);
      var offStr = 'GMT' + sign + pad2(Math.floor(abs / 60)) + pad2(abs % 60);
      return parts.weekday + ' ' + parts.month + ' ' + parts.day + ' ' +
        parts.year + ' ' + parts.hour + ':' + parts.minute + ':' +
        parts.second + ' ' + offStr + ' (' + (parts.timeZoneName || TZ) + ')';
    };
    asNative(_toString, 'toString');
    try { Date.prototype.toString = _toString; } catch (e) {}

    // Intl.DateTimeFormat: inject TZ when no explicit timeZone provided,
    // so `resolvedOptions().timeZone` reports the spoofed zone.
    function PatchedDTF(locales, options) {
      options = options || {};
      if (!options.timeZone) {
        options = Object.assign({}, options, { timeZone: TZ });
      }
      // Support being called without `new` per spec.
      if (!(this instanceof PatchedDTF)) {
        return new _nativeDTF(locales, options);
      }
      return new _nativeDTF(locales, options);
    }
    PatchedDTF.prototype = _nativeDTF.prototype;
    PatchedDTF.supportedLocalesOf = _nativeDTF.supportedLocalesOf
      ? _nativeDTF.supportedLocalesOf.bind(_nativeDTF) : undefined;
    asNative(PatchedDTF, 'DateTimeFormat');
    try { Intl.DateTimeFormat = PatchedDTF; } catch (e) {}
  }

  // --- WebRTC policy ---
  if (WRTC === 'off') {
    var _blocked = function RTCPeerConnection() {
      throw new Error('WebRTC disabled');
    };
    asNative(_blocked, 'RTCPeerConnection');
    try { window.RTCPeerConnection = _blocked; } catch (e) {}
    try { window.webkitRTCPeerConnection = _blocked; } catch (e) {}
  } else if (WRTC === 'relay') {
    var _RealRTC = window.RTCPeerConnection || window.webkitRTCPeerConnection;
    if (_RealRTC) {
      var _Patched = function RTCPeerConnection(config) {
        config = config || {};
        config.iceTransportPolicy = 'relay';
        var pc = new _RealRTC(config);
        var _origSetLocal = pc.setLocalDescription.bind(pc);
        pc.setLocalDescription = function(desc) {
          if (desc && typeof desc.sdp === 'string') {
            desc.sdp = desc.sdp.split('\r\n').filter(function(line) {
              if (line.indexOf('a=candidate:') !== 0) return true;
              return line.indexOf(' typ relay') !== -1;
            }).join('\r\n');
          }
          return _origSetLocal(desc);
        };
        return pc;
      };
      _Patched.prototype = _RealRTC.prototype;
      asNative(_Patched, 'RTCPeerConnection');
      try { window.RTCPeerConnection = _Patched; } catch (e) {}
      try { window.webkitRTCPeerConnection = _Patched; } catch (e) {}
    }
  }
})();
