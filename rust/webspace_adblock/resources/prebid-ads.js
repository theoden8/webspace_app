// SPDX-License-Identifier: MIT
//
// Stands in for prebid-ads.js, a bait script a page loads to learn whether
// ads can run, which uBlock Origin's Resources Library describes by the two
// globals the page reads once it loads: here ads can run (canRunAds) and no
// ad blocker is active (isAdBlockActive).
(function () {
  'use strict';
  window.canRunAds = true;
  window.isAdBlockActive = false;
})();
