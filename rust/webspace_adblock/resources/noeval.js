// SPDX-License-Identifier: MIT
//
// Stands in for uBlock Origin's noeval.js, as its Resources Library describes
// it: the page can no longer run code through eval(), and each attempt is
// reported. Here window.eval runs nothing, returns undefined and writes what
// it was given to the page's console. Only eval: Function() and a string
// handed to setTimeout() still run.
(function () {
  'use strict';
  window.eval = function (code) {
    console.warn('eval() was kept from running', code);
  };
})();
