// SPDX-License-Identifier: MIT
//
// Stands in for the AMP runtime, cdn.ampproject.org's v0.js. Without it an
// AMP page stays blank for eight seconds: the AMP boilerplate (amphtml's
// docs/spec/amp-boilerplate.md) hides the body behind an 8s animation that
// the runtime ends once it loads. Here the boilerplate's styles are removed,
// at once and again when the document is parsed, so the page shows as it
// does with scripts off. No AMP component runs.
(function () {
  'use strict';
  const lift = () => {
    for (const style of document.querySelectorAll('style[amp-boilerplate]')) style.remove();
  };
  lift();
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', lift, { once: true });
})();
