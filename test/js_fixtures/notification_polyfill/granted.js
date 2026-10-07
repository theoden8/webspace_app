(function() {
  var SITE_ID = "site-fixture";
  var permission = 'granted';
  function deliver(title, options) {
    options = options || {};
    window.flutter_inappwebview.callHandler('webNotification', {
      title: String(title),
      body: String(options.body || ''),
      icon: String(options.icon || ''),
      tag: String(options.tag || ''),
      siteId: SITE_ID
    });
  }
  function blocked(api, title) {
    try { console.warn('[WebSpace] ' + api + '("' + title + '") suppressed: permission ' + permission); } catch (e) {}
  }
  function Notification(title, options) {
    if (permission !== 'granted') { blocked('Notification', title); return; }
    deliver(title, options);
  }
  Notification.permission = permission;
  Notification.requestPermission = function(cb) {
    var p = window.flutter_inappwebview.callHandler('webNotificationRequestPermission', {siteId: SITE_ID})
      .then(function(result) { permission = result; Notification.permission = result; return result; });
    if (typeof cb === 'function') p.then(cb);
    return p;
  };
  Object.defineProperty(window, 'Notification', { value: Notification, writable: false, configurable: false });
  // Page-context ServiceWorkerRegistration.showNotification(). Catches sites
  // that post notifications from the page after `navigator.serviceWorker.ready`.
  // Notifications raised from INSIDE the worker's own `push`/`message` handler
  // run in the worker global scope, which a page-injected script cannot reach —
  // those (true server-driven web push) remain unsupported by design.
  try {
    if (window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype) {
      ServiceWorkerRegistration.prototype.showNotification = function(title, options) {
        if (permission !== 'granted') { blocked('showNotification', title); return Promise.resolve(); }
        deliver(title, options);
        return Promise.resolve();
      };
      ServiceWorkerRegistration.prototype.getNotifications = function() { return Promise.resolve([]); };
    }
  } catch (e) {}
})();