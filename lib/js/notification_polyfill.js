// Replaces `Notification` and the page-context
// `ServiceWorkerRegistration.showNotification` with posts to the
// `webNotification` handler, under the site's own permission (NOTIF-001).
// The handler, not this script, decides which site a post belongs to, so no
// frame is told the site's id (NOTIF-010).
(function() {
  // The site's notifications off means denied everywhere; on, each frame
  // starts at 'default' and adopts the real per-frame answer the handler
  // computes from the platform's frame origin (NOTIF-020, PERM-002). A foreign
  // frame never reads the site's 'granted'; the config carries no origin logic.
  var permission = CONFIG.notificationsEnabled ? 'default' : 'denied';
  function setPermission(value) {
    if (value) { permission = value; Notification.permission = value; }
  }
  function deliver(title, options) {
    options = options || {};
    window.flutter_inappwebview.callHandler('webNotification', {
      title: String(title),
      body: String(options.body || ''),
      icon: String(options.icon || ''),
      tag: String(options.tag || '')
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
    var p = window.flutter_inappwebview.callHandler('webNotificationRequestPermission')
      .then(function(result) { setPermission(result); return result; });
    if (typeof cb === 'function') p.then(cb);
    return p;
  };
  Object.defineProperty(window, 'Notification', { value: Notification, writable: false, configurable: false });
  // Adopt this frame's real permission at load, so the site's own documents
  // read 'granted' and a foreign frame reads its own answer, never the site's.
  try {
    window.flutter_inappwebview.callHandler('webNotificationPermission')
      .then(setPermission);
  } catch (e) {}
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