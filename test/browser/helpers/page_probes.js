// Page-side code more than one browser test runs.

// Records every CSP violation the document reports into
// window.__cspViolations, so a test proves the premise (the browser really
// did refuse something) rather than assuming it. A second install (the
// victim page serves it too) keeps the first's record.
function recordCspViolations() {
  if (window.__cspViolations) return;
  window.__cspViolations = [];
  document.addEventListener('securitypolicyviolation', function (e) {
    window.__cspViolations.push({
      directive: e.violatedDirective,
      blocked: e.blockedURI,
      sample: e.sample,
    });
  }, true);
}

module.exports = { recordCspViolations };
