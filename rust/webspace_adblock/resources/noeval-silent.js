// SPDX-License-Identifier: MIT
//
// Stands in for uBlock Origin's noeval-silent.js, as its Resources Library
// describes it: the page can no longer run code through eval(). Here
// window.eval runs nothing, returns undefined and says nothing. Only eval:
// Function() and a string handed to setTimeout() still run.
(function () {
  'use strict';
  window.eval = function () {};
})();
