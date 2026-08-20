// Two-origin HTTP harness for the attacker-page tier.
//
// csp_server.js serves a single page for the blob/CSP tests. This one
// adds what an attacker scenario needs: a victim origin whose CSP is
// configurable per test and whose page loads only external scripts (so
// a strict `script-src 'self'` is actually meaningful), plus a separate
// origin that answers with no CORS headers so cross-origin reads fail
// the way they do in the wild.
//
// Distinct ports are distinct origins for both CSP and the same-origin
// policy, which is all these tests need.

const http = require('node:http');

const NO_STORE = { 'Cache-Control': 'no-store' };

// Records CSP violations so a test can prove the *premise* — that the
// browser really did refuse the injected script — rather than assuming
// it. Must be an external script: the pages under test forbid inline.
const VIOLATION_RECORDER = `
window.__cspViolations = [];
document.addEventListener('securitypolicyviolation', function (e) {
  window.__cspViolations.push({
    directive: e.violatedDirective,
    blocked: e.blockedURI,
    sample: e.sample,
  });
});`;

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        origin: `http://127.0.0.1:${port}`,
        url: `http://127.0.0.1:${port}/`,
        // Chromium holds keep-alive sockets open; server.close() alone
        // waits them out and turns teardown into tens of seconds.
        close: () => new Promise((r) => {
          server.closeAllConnections();
          server.close(r);
        }),
      });
    });
  });
}

// `scripts` maps a filename to JS source served from this origin, and
// each is included in the page in insertion order. They run as ordinary
// first-party page scripts — the point being that everything they reach
// is reachable by any script the site itself loads.
// `scripts` are included in the page; `assets` are served from the same
// origin but not referenced, for worker scripts and the like.
function startVictim({ csp, scripts = {}, assets = {} } = {}) {
  const policy = csp || "default-src 'self'; script-src 'self'";
  const names = Object.keys(scripts);

  const page = `<!doctype html>
<html><head><meta charset="utf-8"><title>victim</title></head><body>
<script src="/__violations.js"></script>
${names.map((n) => `<script src="/${n}"></script>`).join('\n')}
</body></html>`;

  const server = http.createServer((req, res) => {
    const name = req.url.replace(/^\//, '').split('?')[0];

    // A same-origin request that dies mid-flight. fetch() surfaces this
    // as a TypeError, same class the CORS failures produce, which is
    // what the shim's fallback keys on.
    if (name === '__reset') {
      req.socket.destroy();
      return;
    }
    if (name === '__violations.js') {
      res.writeHead(200, { 'Content-Type': 'text/javascript', ...NO_STORE });
      res.end(VIOLATION_RECORDER);
      return;
    }
    if (Object.prototype.hasOwnProperty.call(assets, name)) {
      res.writeHead(200, { 'Content-Type': 'text/javascript', ...NO_STORE });
      res.end(assets[name]);
      return;
    }
    if (Object.prototype.hasOwnProperty.call(scripts, name)) {
      res.writeHead(200, { 'Content-Type': 'text/javascript', ...NO_STORE });
      res.end(scripts[name]);
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': policy,
      ...NO_STORE,
    });
    res.end(page);
  });

  return listen(server);
}

// A different origin that never sends Access-Control-Allow-Origin, so
// the victim page cannot read it with an ordinary fetch.
function startThirdParty({ secret = '{"secret":"third-party-only"}' } = {}) {
  const server = http.createServer((req, res) => {
    const name = req.url.replace(/^\//, '').split('?')[0];
    if (name === 'frame.html') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', ...NO_STORE });
      res.end('<!doctype html><html><body>third party frame</body></html>');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json', ...NO_STORE });
    res.end(secret);
  });

  return listen(server);
}

module.exports = { startVictim, startThirdParty };
