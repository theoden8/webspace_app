(function() {
  try {
    function defineGetter(obj, name, value) {
      try {
        Object.defineProperty(obj, name, {
          configurable: true,
          enumerable: true,
          get: function() { return value; },
        });
      } catch (e) {}
    }
    var NavProto = (typeof Navigator !== 'undefined' && Navigator.prototype)
        ? Navigator.prototype
        : null;
    if (NavProto) {
      defineGetter(NavProto, 'doNotTrack', '1');
      defineGetter(NavProto, 'msDoNotTrack', '1');
      defineGetter(NavProto, 'globalPrivacyControl', true);
    }
    if (typeof window !== 'undefined') {
      defineGetter(window, 'doNotTrack', '1');
    }
  } catch (e) {}
})();
