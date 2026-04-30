// Tiny HTTP server that serves a page with a strict
// `Content-Security-Policy: connect-src 'none'` header. The page mints
// a Blob and stashes the URL on `window.__pageBlobUrl` so the test can
// hand it to the IIFE.
//
// `connect-src 'none'` blocks fetch / XHR / EventSource / WebSocket and,
// crucially for our fix, fetch against `blob:` URLs that aren't
// whitelisted. This mirrors the github.com failure mode that motivated
// the shim.

const http = require('node:http');

function html() {
  return `<!doctype html>
<html><head><meta charset="utf-8"></head><body>
<script>
  // Mint a Blob in the main frame, exactly the way GitHub's attachment
  // download flow does. Stash the URL where the test can read it.
  (function () {
    const blob = new Blob(['hello world'], { type: 'text/plain' });
    window.__pageBlobUrl = URL.createObjectURL(blob);
    window.__pageBlobBytes = 'hello world';
    window.__pageBlobMime = 'text/plain';
  })();

  // Listener for CSP violations so the test can inspect them.
  window.__cspViolations = [];
  document.addEventListener('securitypolicyviolation', function (e) {
    window.__cspViolations.push({
      directive: e.violatedDirective,
      blocked: e.blockedURI,
      sample: e.sample,
    });
  });
</script>
</body></html>`;
}

function start() {
  const server = http.createServer((req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      // 'self' for the page itself, 'unsafe-inline' for the inline
      // script above (the only one we need). connect-src 'none' is the
      // bit under test — every fetch / XHR / blob fetch should be
      // refused.
      'Content-Security-Policy':
        "default-src 'self'; script-src 'self' 'unsafe-inline'; connect-src 'none'",
    });
    res.end(html());
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}/`,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

module.exports = { start };
