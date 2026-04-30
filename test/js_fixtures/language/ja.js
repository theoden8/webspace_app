(function() {
  try {
    var lang = "ja";
    var langs = Object.freeze([lang]);
    Object.defineProperty(Navigator.prototype, 'language', {
      configurable: true, get: function() { return lang; }
    });
    Object.defineProperty(Navigator.prototype, 'languages', {
      configurable: true, get: function() { return langs; }
    });
    if (typeof Intl !== 'undefined' && Intl.DateTimeFormat) {
      var proto = Intl.DateTimeFormat.prototype;
      var orig = proto.resolvedOptions;
      proto.resolvedOptions = function() {
        var r = orig.apply(this, arguments);
        r.locale = lang;
        return r;
      };
    }
  } catch (e) {}
})();
