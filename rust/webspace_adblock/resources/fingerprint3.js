// SPDX-License-Identifier: MIT
//
// Stands in for FingerprintJS 3 loaded by a script tag (iife.min.js), with
// the API its 3.4 API reference (docs/api.md) documents, collecting nothing:
//   FingerprintJS.load([options])  a promise of an agent
//   agent.get()                    a promise of { visitorId: id,
//                                  confidence: { score: 0 }, components: {},
//                                  version: '3.4.2' }
//   FingerprintJS.hashComponents(components)          id
//   FingerprintJS.componentsToDebugString(components) the components as JSON
// id is 32 random hex digits drawn once per page load, which the score of 0
// owns up to. A page that imports the library as a module gets nothing from
// a classic script, this one included.
(function () {
  'use strict';
  const id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
    (b) => b.toString(16).padStart(2, '0')).join('');
  const agent = {
    get() {
      return Promise.resolve({ visitorId: id, confidence: { score: 0 }, components: {}, version: '3.4.2' });
    },
  };
  window.FingerprintJS = {
    load() { return Promise.resolve(agent); },
    hashComponents() { return id; },
    componentsToDebugString(components) { return JSON.stringify(components ?? {}); },
  };
})();
