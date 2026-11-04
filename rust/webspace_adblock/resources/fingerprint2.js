// SPDX-License-Identifier: MIT
//
// Stands in for FingerprintJS 2 (fingerprint2.js), with the API its 2.1
// README documents, collecting nothing:
//   Fingerprint2.get([options], done)     done([]) a tick later: no components
//   Fingerprint2.getPromise([options])    a promise of []
//   Fingerprint2.getV18([options], done)  done(id, []) a tick later
//   new Fingerprint2([options]).get(done) the same, as 1.8 called it
//   Fingerprint2.x64hash128(text, seed)   id
//   Fingerprint2.NOT_AVAILABLE, .ERROR, .EXCLUDED  the documented constants
// id is 32 random hex digits drawn once per page load, so a page that keys on
// it sees a new visitor each time rather than one every user shares.
(function () {
  'use strict';
  const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
    (b) => b.toString(16).padStart(2, '0')).join('');
  const later = (args, ...result) => {
    const done = args.find((a) => typeof a === 'function');
    if (done) setTimeout(() => done(...result), 1);
  };
  function Fingerprint2() {}
  Fingerprint2.prototype.get = function (...args) { later(args, id, []); };
  Fingerprint2.get = function (...args) { later(args, []); };
  Fingerprint2.getPromise = function () { return Promise.resolve([]); };
  Fingerprint2.getV18 = function (...args) { later(args, id, []); };
  Fingerprint2.x64hash128 = function () { return id; };
  Fingerprint2.NOT_AVAILABLE = 'not available';
  Fingerprint2.ERROR = 'error';
  Fingerprint2.EXCLUDED = 'excluded';
  window.Fingerprint2 = Fingerprint2;
})();
