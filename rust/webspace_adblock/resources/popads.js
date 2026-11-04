// SPDX-License-Identifier: MIT
//
// Stands in for uBlock Origin's popads.js, as its Resources Library describes
// it: abort-on-property-write for PopAds and popns, the globals PopAds' ad
// code sets. A write to either throws a ReferenceError, which stops the
// script that makes it, and a read gives undefined. The trap cannot be
// redefined; a name the page already made unconfigurable is left as it is.
(function () {
  'use strict';
  for (const name of ['PopAds', 'popns']) {
    if (Object.getOwnPropertyDescriptor(window, name)?.configurable === false) continue;
    Object.defineProperty(window, name, {
      configurable: false,
      get() { return undefined; },
      set() { throw new ReferenceError(`${name} is not defined`); },
    });
  }
})();
